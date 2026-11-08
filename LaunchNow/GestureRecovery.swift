import AppKit

extension NSView {
    /// 拖拽由事件监听接管、要吞掉鼠标抬起时调用：把还在跟踪这次按下的手势（SwiftUI 按钮等）取消掉。
    /// 不然它等不到抬起，一直卡在「进行中」，AppKit 之后会忽略窗口里所有的点击，面板像卡死一样
    func cancelActiveGestureRecognizers() {
        for recognizer in gestureRecognizers where recognizer.state == .began || recognizer.state == .changed {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
        for subview in subviews {
            subview.cancelActiveGestureRecognizers()
        }
    }
}
