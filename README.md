<p align="center">
  <img width="128" height="128" alt="LaunchNow" src="https://github.com/user-attachments/assets/b4bf72d3-a272-44ad-ab9a-d02248a9fa67" />
</p>

<h1 align="center">LaunchNow</h1>

<p align="center">
  <a href="https://github.com/ggkevinnnn/LaunchNow/blob/main/LICENSE"><img src="https://img.shields.io/github/license/ggkevinnnn/LaunchNow" alt="License" /></a>
  <a href="#"><img src="https://img.shields.io/badge/language-Swift-orange.svg" alt="Language" /></a>
  <a href="https://github.com/ggkevinnnn/LaunchNow/releases"><img src="https://img.shields.io/github/downloads/ggkevinnnn/LaunchNow/total" alt="Downloads" /></a>
</p>

## 这个改版和原版有什么不同

这是 [ggkevinnnn/LaunchNow](https://github.com/ggkevinnnn/LaunchNow) 的自用改版，基于原版 1.9.2。下面列出新增和改动的地方，原版的说明在后面。

> A personal fork of [ggkevinnnn/LaunchNow](https://github.com/ggkevinnnn/LaunchNow) (based on 1.9.2), adding pinyin search, auto-switching to an English keyboard, an overall size setting, iOS-style drag into folders with spring-loaded folders, and a command-line build. The original README follows below.

### 搜索与输入

- **拼音搜索**：全拼、首字母、混着打都行，`xiaohongshu`、`xhs`、`xiaohs` 都能找到「小红书」。多音字按词读，`yinyue` 能找到「音乐」。
- **也能搜英文文件名**：比如 `wechat` 能找到「微信」。iPhone / iPad 版 App 还能搜包里自带的中文名，比如 rednote 能用 `xiaohongshu` 找到。
- **打开时自动切到英文键盘**，打字直接进搜索框；收起时切回原来的输入法。需要系统输入法里开着 ABC 或 U.S. 这类英文键盘，搜狗、微信输入法等第三方输入法也适用。

### 拖拽和文件夹

- **拖到文件夹或另一个 App 上**：目标后面亮起一块托板，拖着的图标缩小一点；松手就放进文件夹或合成新文件夹。
- **插到两个图标中间**：在中间停约 0.25 秒，两边才让开。只是路过不会让位，正要放进去的文件夹不会被挤走。
- **停在文件夹上约 0.7 秒自动展开**（类似 iOS），可以接着在里面拖到想放的位置；拖出文件夹范围，文件夹就关上，回到主界面继续拖。
- 修复了几处拖拽之后点什么都没反应的卡死。

### 外观和窗口

- **「整体大小」**（设置里，60%–100%）：窗口、图标、名字、间距一起按比例缩放，拖窗口边缘效果相同。屏幕放不下时只临时缩小，不改设置。
- 多显示器下，面板在鼠标所在的屏幕打开。
- 图标按屏幕实际像素绘制，不再发糊。窗口改为 7:6，按屏幕大小放大。
- 名字单行显示完整，放不下就自动缩小字号；优先用系统的本地化名称（显示「微信」而不是 WeChat）。
- 设置里可以换 App 图标。
- 打开时不卡：收起时不再清图标缓存、重扫全部 App（装、删、更新 App 由文件监听自动更新）；在 LaunchNow 里关掉了光标旁的输入法指示器（「ABC」小气泡），它和面板同步时常超时，每次让画面停 0.5 秒。

### 快捷键和其它

- 全局快捷键 **⌥空格** 打开 / 收起（⌘空格 留给系统的聚焦搜索）。收起后，焦点还给之前在用的 App。
- 从「应用程序」文件夹第一次运行时，自动加入登录项；开机后在后台待命，不弹窗口。
- 新装的 App 马上出现在当前页末尾。文件名以 `-backup` 结尾的回滚副本不显示。
- 右键菜单：在访达中显示、从 LaunchNow 中隐藏、移到废纸篓。
- 不再从原作者仓库检查更新，免得原版覆盖改版。
- `tools/import_launchos.py`：把 LaunchOS 的图标排列导入 LaunchNow。

### 编译和安装

这个改版没有打包好的安装包，需要自己编译。要求 Apple 芯片的 Mac、macOS 26 及以上，装好 Command Line Tools 就行，不需要 Xcode：

```bash
./build.sh            # 编译到 build/LaunchNow.app
./build.sh --install  # 编译并替换 /Applications/LaunchNow.app
```

- **布局存储**：布局改存为 JSON 文件（`~/Library/Application Support/LaunchNow/layout.json`），不再用 SwiftData。
- **Xcode 工程**：没有同步新增的文件，请用 `build.sh` 编译。
- **签名**：默认用 ad-hoc 签名，每次重新编译后，可能要重新授予辅助功能权限（四指捏合手势要用）。想用自己的签名身份，就在仓库根目录新建 `build.local.sh`（已在 `.gitignore` 里，不会被提交）：

```bash
BUNDLE_ID=com.example.LaunchNow
IDENTITY="你的代码签名身份名称"
# 签名身份放在单独的钥匙串里时，再写上钥匙串和它的密码：
# SIGNING_KEYCHAIN="$HOME/Library/Keychains/xxx.keychain-db"
# SIGNING_KEYCHAIN_PASSWORD=...
```

以下是原版 README。

---

<a name="readme-en"></a>


**LaunchNow** is an alternative macOS Launchpad application designed for macOS Sequoia and later. It provides a smoother, more customizable launchpad experience with both **Tahoe-style (macOS 15)** and **Classic-style** interfaces.

### ✨ Features

- **🎨 Dual Style Support** — Switch between the fullscreen Launchpad style and the new window style
- **📁 Folder Management** — Drag an app onto another app to quickly create a folder; drag apps in/out of folders freely
- **🔄 Icon Rearrangement** — Drag and drop app icons to customize your layout with smooth animations
- **🔒 Lock Mode** — Hold the `Option` key to enable lock mode, preventing other icons from moving while you create folders or add apps to folders
- **🔍 App Search** — Real-time search across all apps including those inside folders
- **⌨️ Full Keyboard Navigation** — Use `Tab` / `Shift+Tab` to flip pages, arrow keys to select apps, and `Return` to launch
- **🖱️ Trackpad Gesture** — 4-finger trackpad gesture support for quick access (configurable)
- **🧹 Hidden Apps** — Hide unwanted apps from the grid without deleting them
- **📦 Import / Export** — Backup and restore your layout configuration
- **📐 Adjustable Icon Size** — Customize icon scale to your preference
- **🪟 Glass Effect** — Enable/disable the frosted glass background effect
- **🌍 Multi-language** — Supports 13 languages with real-time language switching
- **📋 Scroll Sensitivity** — Adjust trackpad/mouse scroll sensitivity for page turning

### 📸 Screenshots

<table>
  <tr>
    <td><img width="960" alt="Tahoe Style" src="https://github.com/user-attachments/assets/69eaf1bb-746e-4c9c-9d38-791dbee14194" /></td>
    <td><img width="960" alt="Classic Style" src="https://github.com/user-attachments/assets/c6bffd5c-9dcf-4b1c-8b34-a9d7f964a78d" /></td>
  </tr>
  <tr>
    <td align="center">Tahoe Style (Windowed)</td>
    <td align="center">Classic Mode (Fullscreen)</td>
  </tr>
</table>

### 🚀 Getting Started

#### Installation

1. Download the latest release from the [Releases page](https://github.com/ggkevinnnn/LaunchNow/releases/latest)
2. Drag `LaunchNow.app` to your `Applications` folder
3. Launch the app — it runs in the background and opens the launchpad window

#### Quick Usage

| Action | How |
|---|---|
| **Open Launchpad** | Click the Dock icon or set a custom trigger |
| **Launch an app** | Click on the app icon |
| **Rearrange icons** | Drag an app to a new position |
| **Create a folder** | Drag one app onto another app |
| **Add to folder** | Drag an app onto a folder |
| **Remove from folder** | Open the folder and drag the app outside |
| **Lock Mode** | Hold `Option` while dragging (recommended for folder operations) |
| **Search** | Type in the search field at the top |
| **Turn pages** | Scroll with trackpad/mouse or use `Tab` / `Shift+Tab` |
| **Keyboard navigation** | Press `↓` or `Return` to activate, then use arrow keys |
| **Close / Hide** | Press `Esc` |

#### Auto Launch (Optional)

Add LaunchNow to your **Login Items** in System Settings → General → Login Items to have it automatically run in the background at startup.

### 🙏 Acknowledgments

Special thanks to all contributors who helped make LaunchNow better:

- Code improvement and optimization by @dizzycoder1112
- Dutch translation by @OABsoftware
- Russian translation by @Leoxoo
- Bulgarian translation by Трифон Иванов
- Japanese translation by @endianoia
- Korean translation by @D-KoLee
- Italian & Turkish translations by @wd006
- Vietnamese translation by @ornithobiograph

### 📄 License

See the [LICENSE](LICENSE) file for details.
