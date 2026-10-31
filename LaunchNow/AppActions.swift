import AppKit
import SwiftUI

// MARK: - 右键菜单里针对单个 App 的操作

enum AppActions {
    /// 系统自带的 App 在只读的系统卷上，删不掉
    static func canMoveToTrash(_ app: AppInfo) -> Bool {
        !app.url.path.hasPrefix("/System/")
    }

    static func revealInFinder(_ app: AppInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    /// 先确认再移到废纸篓；成功后文件监听会自动把它从 LaunchNow 里拿掉。
    /// 弹框时窗口会失去焦点，用 isPresentingAlert 拦住自动收起
    static func confirmAndMoveToTrash(_ app: AppInfo, appStore: AppStore) {
        appStore.isPresentingAlert = true
        defer { appStore.isPresentingAlert = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = app.icon
        alert.messageText = String(format: NSLocalizedString("MoveToTrashConfirmTitle", comment: ""), app.name)
        alert.informativeText = NSLocalizedString("MoveToTrashConfirmMessage", comment: "")
        alert.addButton(withTitle: NSLocalizedString("MoveToTrash", comment: "")).hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: app.url, resultingItemURL: nil)
        } catch {
            // 用安装包装的 App 多半归 root 所有，普通权限挪不动，交给访达（会要密码）
            let failure = NSAlert()
            failure.icon = app.icon
            failure.messageText = String(format: NSLocalizedString("MoveToTrashFailedTitle", comment: ""), app.name)
            failure.informativeText = NSLocalizedString("MoveToTrashFailedMessage", comment: "")
            failure.addButton(withTitle: NSLocalizedString("ShowInFinder", comment: ""))
            failure.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if failure.runModal() == .alertFirstButtonReturn {
                revealInFinder(app)
            }
        }
    }
}

/// 右键菜单：在访达中显示、从 LaunchNow 中隐藏、移到废纸篓
struct AppContextMenuItems: View {
    let app: AppInfo
    let appStore: AppStore

    var body: some View {
        Button(NSLocalizedString("ShowInFinder", comment: "")) {
            AppActions.revealInFinder(app)
        }
        Button(NSLocalizedString("HideFromLaunchNow", comment: "")) {
            appStore.setAppHidden(true, app: app)
        }
        Divider()
        Button(NSLocalizedString("MoveToTrashEllipsis", comment: ""), role: .destructive) {
            AppActions.confirmAndMoveToTrash(app, appStore: appStore)
        }
        .disabled(!AppActions.canMoveToTrash(app))
    }
}
