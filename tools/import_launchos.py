"""Import the LaunchOS grid (Core Data SQLite) into LaunchNow's layout.json.

usage: python3 tools/import_launchos.py [LaunchOS.sqlite] [layout.json]

Reads LaunchOS read-only. Quit LaunchNow first: it rewrites layout.json when its
window hides, which would overwrite the import. The previous layout.json is kept
as layout.json.bak-<timestamp>.
"""
import json, shutil, sqlite3, subprocess, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlparse

PAGE_SIZE = 35  # LaunchNow AppStore.itemsPerPage (7 x 5), same grid as LaunchOS
SUPPORT = Path.home() / "Library/Application Support"
src = Path(sys.argv[1]) if len(sys.argv) > 1 else SUPPORT / "LaunchOS/LaunchOS.sqlite"
dst = Path(sys.argv[2]) if len(sys.argv) > 2 else SUPPORT / "LaunchNow/layout.json"

if subprocess.run(["pgrep", "-x", "LaunchNow"], capture_output=True).returncode == 0:
    sys.exit("LaunchNow is running; quit it first so it does not overwrite the import.")


def path_of(url):
    return unquote(urlparse(url).path).rstrip("/")


db = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
slots = db.execute("select Z_PK, ZISFOLDER, ZNAME from ZGROUPENTITY order by ZPAGE, ZORDER").fetchall()
apps_in = {}
for group, url in db.execute("select ZGROUP, ZURL from ZAPPENTITY where coalesce(ZHIDDEN, 0) = 0 "
                             "order by ZGROUP, Z_FOK_GROUP"):
    apps_in.setdefault(group, []).append(path_of(url))

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
entries = []
for pk, is_folder, name in slots:
    paths = apps_in.get(pk, [])
    if not paths:
        continue
    idx = len(entries)
    row = {"slotId": f"page-{idx // PAGE_SIZE}-pos-{idx % PAGE_SIZE}",
           "pageIndex": idx // PAGE_SIZE, "position": idx % PAGE_SIZE,
           "createdAt": now, "updatedAt": now}
    if is_folder:
        row.update(kind="folder", folderId=str(uuid.uuid4()).upper(),
                   folderName=name or "未命名", appPaths=paths)
    else:
        row.update(kind="app", appPath=paths[0], appPaths=[])
    entries.append(row)

dst.parent.mkdir(parents=True, exist_ok=True)
if dst.exists():
    backup = dst.with_name(f"{dst.name}.bak-{datetime.now():%Y%m%d-%H%M%S}")
    shutil.copy2(dst, backup)
    print(f"backup: {backup}")
dst.write_text(json.dumps({"version": 1, "pageEntries": entries, "topItems": []},
                          ensure_ascii=False, indent=2, sort_keys=True))

folders = [e for e in entries if e["kind"] == "folder"]
print(f"wrote {dst}: {len(entries)} slots ({len(folders)} folders, "
      f"{sum(len(f['appPaths']) for f in folders)} apps inside), "
      f"{(len(entries) + PAGE_SIZE - 1) // PAGE_SIZE} page(s)")
