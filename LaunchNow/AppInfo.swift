import Foundation
import AppKit

struct AppInfo: Identifiable, Equatable, Hashable {
    let name: String
    let icon: NSImage
    let url: URL

    // 使用应用路径作为稳定唯一标识
    var id: String { url.path }

    /// 显示用的图标：扫描时拿到的图标偶尔是空的，就现取一次系统图标
    var displayIcon: NSImage {
        icon.size.width > 0 && icon.size.height > 0 ? icon : NSWorkspace.shared.icon(forFile: url.path)
    }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }

    // MARK: - 创建 AppInfo
    static func from(url: URL) -> AppInfo {
        let name = localizedAppName(for: url)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return AppInfo(name: name, icon: icon, url: url)
    }
}
