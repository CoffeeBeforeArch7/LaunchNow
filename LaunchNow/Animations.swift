import SwiftUI

enum LNAnimations {
    static let smooth: Animation = .smooth
    static let easeInOut: Animation = .easeInOut(duration: 0.3)
    static let folder: Animation = .smooth(duration: 0.35)
    /// 拖着的 App 停到文件夹 / 另一个 App 上：目标像 iOS 那样弹一下放大
    static let dropTarget: Animation = .spring(response: 0.28, dampingFraction: 0.6)
}

