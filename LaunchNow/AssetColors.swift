import SwiftUI
import AppKit

// Xcode 会根据 Assets.xcassets/FoundaryColor 自动生成 `Color.foundary`；
// 命令行编译没有资源编译器，这里按同样的取值手写（浅色白色，深色半透明灰）。
extension Color {
    static let foundary = Color(nsColor: NSColor(name: "FoundaryColor") { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(displayP3Red: 0.4, green: 0.4, blue: 0.4, alpha: 0.7)
        }
        return NSColor(displayP3Red: 1, green: 1, blue: 1, alpha: 1)
    })
}
