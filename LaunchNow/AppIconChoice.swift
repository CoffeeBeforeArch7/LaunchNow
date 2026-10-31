import AppKit

// MARK: - 可选 App 图标（设置 ▸ App 图标）
//
// 选中的图标写到 LaunchNow.app 上（访达、程序坞、启动台里看到的都是它）。
// 重新编译安装会换回包内默认图标，所以启动时再套用一次。

enum AppIconChoice: String, CaseIterable, Identifiable {
    case rocket   // 经典火箭：包内默认图标
    case apps     // macOS「应用程序」图标
    case grid     // 简约网格

    static let defaultsKey = "appIconChoice"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rocket: return "经典火箭"
        case .apps: return "系统应用程序"
        case .grid: return "简约网格"
        }
    }

    static var current: AppIconChoice {
        AppIconChoice(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .rocket
    }

    /// 设置页里的预览图
    var preview: NSImage {
        customImage ?? Self.bundledIcon
    }

    /// nil 表示用包内默认图标
    private var customImage: NSImage? {
        switch self {
        case .rocket: return nil
        case .apps: return NSWorkspace.shared.icon(forFile: "/System/Applications/Apps.app")
        case .grid: return Self.gridIcon
        }
    }

    /// 保存选择并套用到 App 上
    func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NSWorkspace.shared.setIcon(customImage, forFile: Bundle.main.bundlePath, options: [])
        NSApp.applicationIconImage = customImage ?? Self.bundledIcon
    }

    /// 启动时调用：非默认图标会在重新安装后丢失，需要再套用
    static func reapplyIfCustom() {
        if current != .rocket {
            current.apply()
        }
    }

    private static let bundledIcon: NSImage =
        Bundle.main.image(forResource: "AppIcon") ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

    /// 蓝紫渐变圆角方块上排 3×3 白色圆角点
    private static let gridIcon: NSImage = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
        let tile = rect.insetBy(dx: 100, dy: 100) // macOS 图标主体占画布约 80%
        let body = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
        NSGradient(starting: NSColor(calibratedRed: 0.33, green: 0.56, blue: 1.0, alpha: 1),
                   ending: NSColor(calibratedRed: 0.58, green: 0.33, blue: 0.96, alpha: 1))?
            .draw(in: body, angle: -90)

        NSColor.white.withAlphaComponent(0.92).setFill()
        let cell = tile.width / 3
        let dot = cell * 0.46
        for row in 0..<3 {
            for column in 0..<3 {
                let origin = NSPoint(x: tile.minX + cell * (CGFloat(column) + 0.5) - dot / 2,
                                     y: tile.minY + cell * (CGFloat(row) + 0.5) - dot / 2)
                NSBezierPath(roundedRect: NSRect(origin: origin, size: NSSize(width: dot, height: dot)),
                             xRadius: dot * 0.28, yRadius: dot * 0.28).fill()
            }
        }
        return true
    }
}
