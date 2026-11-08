import SwiftUI
import AppKit
import Combine
import CoreServices
import QuartzCore
import ServiceManagement

extension Notification.Name {
    static let launchpadWindowShown = Notification.Name("LaunchpadWindowShown")
    static let launchpadWindowHidden = Notification.Name("LaunchpadWindowHidden")
    static let launchpadFocusSearchField = Notification.Name("LaunchpadFocusSearchField")
}

class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@main
struct LaunchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {}
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    
    private enum GesturePreviewMode {
        case showing
        case hiding
    }
    
    private enum GestureCommittedAction {
        case show
        case hide
    }

    private enum WindowTransitionDirection {
        case show
        case hide
    }

    private var window: NSWindow?
    /// 「整体大小」最小 60%：840 × 0.6 = 504 高，按 7:6 宽 588
    private let minimumContentSize = NSSize(width: 588, height: 504)
    /// 窗口宽高比 7:6：7 列 5 行、带名字的网格正好是这个比例，图标能放大又不挤
    private static let windowAspect: CGFloat = 7.0 / 6.0
    /// 「整体大小」100% 时的窗口高度，也是默认大小（宽 980）。拖窗口边缘最大也到这里
    private static let referenceHeight: CGFloat = 840
    /// 打开时切到英文键盘，收起时切回原来的输入法
    private let inputSource = InputSourceSwitcher()
    /// 打开前在用的 App：收起时把焦点还给它（不然焦点留在没有窗口的 LaunchNow 上，按键没反应）
    private var previousApp: NSRunningApplication?
    /// 打开别的 App 时不还焦点，交给新打开的那个
    private var refocusPreviousOnHide = true
    private var lastShowAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var gesturePreviewMode: GesturePreviewMode?
    private var gesturePreviewMadeVisible = false
    private var gesturePreviewTargetRect: NSRect?
    private var gestureCommittedAction: GestureCommittedAction?
    private var gesturePreviewProgress: CGFloat = 0
    private var gestureContinuityProgress: CGFloat?
    private var gesturePreviewActivated = false
    private var gestureSearchFocusAssigned = false
    private var isAnimatingWindowTransition = false
    /// 旧版存窗口 frame 的键，只在迁移时读一次（现在窗口大小只由「整体大小」决定，见 AppStore.panelScale）
    private static let windowFrameDefaultsKey = "savedWindowFrame"
    private var isRecentering: Bool = false
    private let showStartScale: CGFloat = 1.4
    private let previewActivationProgress: CGFloat = 0.08
    private let gestureCompletionProgressThreshold: CGFloat = 0.52
    private let previewSmoothingFactor: CGFloat = 0.42
    
    let appStore = AppStore()
    var modelContext: ModelContext?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先套用自选图标，再扫描 App：重新安装会冲掉自选图标，晚了的话缓存里存的是默认的火箭
        AppIconChoice.reapplyIfCustom()
        Self.shared = self

        migrateWindowLayoutIfNeeded()
        setupWindow()
        bindGestureSettings()
        appStore.performInitialScanIfNeeded()
        appStore.startAutoRescan()
        // 开机自启时静默待命，只有手动打开时才显示
        if !launchedAsLoginItem {
            requestShowWindow()
        }
        GlobalHotKey.shared.register { [weak self] in self?.toggleWindow() }
        registerLoginItemOnce()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// 第 2 版布局：窗口按屏幕变大、改成 7:6，图标随之变大。旧版存的窗口尺寸和图标缩放作废一次。
    /// 第 3 版：不再存窗口 frame，「整体大小」单独存；按旧 frame 的高度换算一次，大小不变
    private func migrateWindowLayoutIfNeeded() {
        let key = "windowLayoutVersion"
        let version = UserDefaults.standard.integer(forKey: key)
        guard version < 3 else { return }
        if version < 2 {
            UserDefaults.standard.removeObject(forKey: Self.windowFrameDefaultsKey)
            appStore.iconScale = 1.0
        }
        if let frame = UserDefaults.standard.dictionary(forKey: Self.windowFrameDefaultsKey),
           let height = frame["height"] as? CGFloat, height > 0 {
            appStore.panelScale = AppStore.clampedPanelScale(Double(height / Self.referenceHeight))
        }
        UserDefaults.standard.removeObject(forKey: Self.windowFrameDefaultsKey)
        UserDefaults.standard.set(3, forKey: key)
    }

    /// 收起并打开 App（或系统设置等网址）：焦点交给新打开的那个，不切回之前的 App
    func hideAndOpen(_ url: URL) {
        refocusPreviousOnHide = false
        requestHideWindow {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开前调用：记下当前在用的 App；切到英文键盘（在 LaunchNow 拿到焦点之前切，第一个字母就是英文）
    private func prepareToShow() {
        inputSource.switchToEnglish()
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = front
    }

    /// 窗口收起后：切回原来的输入法（一般在开始收起时已经切过，这里兜底手势收起）；
    /// 按 Esc / ⌥空格收起时把焦点还给之前的 App（点了别的 App 或打开了 App 的，焦点已经在那边，不用还）
    private func didHideWindow() {
        inputSource.restore()
        if refocusPreviousOnHide, NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate(options: [])
        }
        previousApp = nil
        refocusPreviousOnHide = true
    }

    /// ⌥空格：显示或隐藏启动台
    func toggleWindow() {
        if window?.isVisible == true {
            requestHideWindow()
        } else {
            requestShowWindow()
        }
    }

    /// 是否由登录项拉起（开机自启）
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// 装进「应用程序」后首次运行时注册开机自启；之后尊重用户在系统设置里的开关
    private func registerLoginItemOnce() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("LaunchNow: login item registration failed: \(error)")
        }
    }

    private func bindGestureSettings() {
        appStore.$isGlobalPinchEnabled
            .combineLatest(appStore.$isFullscreenMode)
            .removeDuplicates { prev, curr in prev.0 == curr.0 && prev.1 == curr.1 }
            .sink { [weak self] isEnabled, isFullscreen in
                guard let self else { return }
                if isEnabled {
                    if isFullscreen {
                        GlobalPinchGestureMonitor.shared.start(
                            promptForAccessibility: true,
                            onPinchIn: { self.registerGestureCommit(.show) },
                            onPinchOut: { self.registerGestureCommit(.hide) },
                            onProgress: { direction, progress in
                                self.applyGestureProgress(direction: direction, progress: progress)
                            },
                            onGestureEnded: {
                                self.finishGesturePreview()
                            }
                        )
                    } else {
                        GlobalPinchGestureMonitor.shared.start(
                            promptForAccessibility: true,
                            onPinchIn: { self.requestShowWindow() },
                            onPinchOut: { self.requestHideWindow() },
                            onProgress: { _, _ in },
                            onGestureEnded: { }
                        )
                    }
                } else {
                    GlobalPinchGestureMonitor.shared.stop()
                    self.cancelGesturePreview()
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupWindow() {
        guard let screen = NSScreen.main else { return }

        // 按「整体大小」在屏幕上居中（全屏模式在显示时再铺满屏幕）
        let rect = centeredRect(for: screen)

        // 非全屏模式下添加 .resizable 允许边缘拖拽调整大小
        let styleMask: NSWindow.StyleMask = appStore.isFullscreenMode
            ? [.borderless, .fullSizeContentView]
            : [.borderless, .fullSizeContentView, .resizable]
        window = BorderlessWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        window?.delegate = self
        window?.isMovable = false
        window?.level = .floating
        window?.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window?.isOpaque = true
        window?.backgroundColor = .clear
        window?.hasShadow = true
        window?.contentAspectRatio = NSSize(width: 7, height: 6)
        window?.contentMinSize = minimumContentSize
        window?.minSize = window?.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size ?? minimumContentSize
        
        // 布局持久化（JSON，固定到 Application Support 目录，避免替换应用后数据丢失）
        if let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let storeURL = appSupport
                .appendingPathComponent("LaunchNow", isDirectory: true)
                .appendingPathComponent(ModelContext.fileName)
            let context = ModelContext(url: storeURL)
            modelContext = context
            appStore.configure(modelContext: context)
        }
        window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore))

        refreshLayoutScale()
        applyCornerRadius()
        applyPreviewVisual(scale: 1, alpha: 1)
        window?.alphaValue = 1
    }

    /// 按窗口实际高度更新面板缩放比例（拖边缘、「整体大小」、换屏、切换全屏都会走到这里）
    private func refreshLayoutScale() {
        guard let window else { return }
        let scale = appStore.isFullscreenMode ? 1 : (window.frame.height / Self.referenceHeight * 100).rounded() / 100
        guard scale != appStore.layoutScale else { return }
        appStore.layoutScale = scale
        applyCornerRadius()
    }

    /// 「整体大小」改了（设置里的滑块、拖完窗口边缘）：按新大小在当前屏幕居中；字号、间距随 windowDidResize 跟着变
    func applyPanelScale() {
        guard let window, !appStore.isFullscreenMode,
              let screen = resolveScreen(for: window) else { return }
        window.setFrame(centeredRect(for: screen), display: true)
    }

    /// 更新设置面板最多能多高：从窗口顶边（设置从这里垂下来）到屏幕可用区底边（程序坞上面）。
    /// 窗口挪动、变大小、程序坞或屏幕变了都要重算
    private func refreshSettingsMaxHeight() {
        guard let window, let screen = resolveScreen(for: window) else { return }
        let height = (window.frame.maxY - screen.visibleFrame.minY - 8).rounded()
        if height != appStore.settingsMaxHeight {
            appStore.settingsMaxHeight = height
        }
    }

    private func finalizeShownState() {
        guard let window = window else { return }
        resetGesturePreviewState()
        // 按「整体大小」在鼠标所在的屏幕居中，全屏模式铺满屏幕
        window.setFrame(targetRectForCurrentScreen(), display: true)
        applyCornerRadius()
        applyPreviewVisual(scale: 1, alpha: 1)
        window.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        lastShowAt = Date()
        NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)
        // 刚启动时第一次打开，开始显示时发的「聚焦搜索框」视图还没收到（onAppear 之后才订阅），这里再发一次
        NotificationCenter.default.post(name: .launchpadFocusSearchField, object: nil)
        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
    }

    func requestShowWindow(completion: (() -> Void)? = nil) {
        guard let window = window else {
            completion?()
            return
        }
        guard !window.isVisible else {
            completion?()
            return
        }
        performWindowTransition(.show, completion: completion)
    }

    private func finalizeHiddenState() {
        resetGesturePreviewState()
        // 兜底：万一有手势卡在「进行中」（AppKit 会因此忽略所有点击），收起时清掉
        window?.contentView?.cancelActiveGestureRecognizers()
        window?.orderOut(nil)
        didHideWindow()
        applyPreviewVisual(scale: 1, alpha: 1)
        window?.alphaValue = 1
        appStore.isSetting = false
        appStore.currentPage = 0
        appStore.searchText = ""
        appStore.openFolder = nil
        appStore.saveAllOrder()
        appStore.refresh()
        NotificationCenter.default.post(name: .launchpadWindowHidden, object: nil)
    }

    func requestHideWindow(completion: (() -> Void)? = nil) {
        guard let window = window else {
            completion?()
            return
        }
        guard window.isVisible else {
            completion?()
            return
        }
        performWindowTransition(.hide, completion: completion)
    }

    private func performWindowTransition(_ direction: WindowTransitionDirection, completion: (() -> Void)? = nil) {
        guard let window = window, window.isVisible, !isAnimatingWindowTransition else {
            if direction == .show, let window, !window.isVisible, !isAnimatingWindowTransition {
                performShowTransition(window: window, completion: completion)
                return
            }
            completion?()
            return
        }
        performHideTransition(window: window, completion: completion)
    }

    private func performShowTransition(window: NSWindow, completion: (() -> Void)? = nil) {
        isAnimatingWindowTransition = true
        resetGesturePreviewState()
        refocusPreviousOnHide = true
        prepareToShow()

        let targetRect = targetRectForCurrentScreen()

        window.setFrame(targetRect, display: true)
        applyCornerRadius()
        refreshSettingsMaxHeight()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
        NotificationCenter.default.post(name: .launchpadFocusSearchField, object: nil)

        if appStore.isFullscreenMode {
            gesturePreviewTargetRect = targetRect
            gesturePreviewMode = .showing
            gesturePreviewMadeVisible = true
            gesturePreviewActivated = true
            applyPreviewVisual(scale: previewScale(for: 0), alpha: previewAlpha(for: 0))
            animatePreviewVisual(toScale: previewScale(for: 1), alpha: previewAlpha(for: 1)) { [weak self] in
                guard let self else { return }
                self.isAnimatingWindowTransition = false
                self.finalizeShownState()
                completion?()
            }
        } else {
            guard let layer = window.contentView?.layer else {
                self.isAnimatingWindowTransition = false
                self.finalizeShownState()
                completion?()
                return
            }
            configurePreviewLayerGeometry()
            animateLayerOpacity(layer, from: 0, to: 1, duration: 0.15, timing: .default) { [weak self] in
                guard let self else { return }
                self.isAnimatingWindowTransition = false
                self.finalizeShownState()
                completion?()
            }
        }
    }

    private func performHideTransition(window: NSWindow, completion: (() -> Void)? = nil) {
        isAnimatingWindowTransition = true
        resetGesturePreviewState()
        // 趁面板还是焦点时切回原来的输入法，接着焦点交给别的 App，中文输入法才真正生效
        inputSource.restore()

        let targetRect = targetRectForCurrentScreen()

        if window.frame != targetRect {
            window.setFrame(targetRect, display: true)
        }
        applyCornerRadius()

        if appStore.isFullscreenMode {
            gesturePreviewTargetRect = targetRect
            gesturePreviewMode = .hiding
            gesturePreviewActivated = true
            applyPreviewVisual(scale: previewScale(for: 1), alpha: previewAlpha(for: 1))
            animatePreviewVisual(toScale: previewScale(for: 0), alpha: previewAlpha(for: 0)) { [weak self] in
                guard let self else { return }
                self.isAnimatingWindowTransition = false
                self.finalizeHiddenState()
                completion?()
            }
        } else {
            guard let layer = window.contentView?.layer else {
                self.isAnimatingWindowTransition = false
                self.finalizeHiddenState()
                completion?()
                return
            }
            configurePreviewLayerGeometry()
            animateLayerOpacity(layer, from: 1, to: 0, duration: 0.15, timing: .default) { [weak self] in
                guard let self else { return }
                self.isAnimatingWindowTransition = false
                self.finalizeHiddenState()
                completion?()
            }
        }
    }
    
    func updateWindowMode(isFullscreen: Bool) {
        guard let window = window else { return }
        guard let screen = getCurrentActiveScreen() ?? NSScreen.main else { return }
        window.setFrame(isFullscreen ? screen.frame : centeredRect(for: screen), display: true)
        window.hasShadow = !isFullscreen
        window.contentAspectRatio = isFullscreen ? NSSize(width: 0, height: 0) : NSSize(width: 7, height: 6)
        // 切换模式时更新 styleMask：非全屏模式下允许边缘拖拽调整大小
        let newStyleMask: NSWindow.StyleMask = isFullscreen
            ? [.borderless, .fullSizeContentView]
            : [.borderless, .fullSizeContentView, .resizable]
        window.styleMask = newStyleMask
        refreshLayoutScale()
        refreshSettingsMaxHeight()
        // 切换模式时重置手势状态和 layer 状态，避免模式间动画污染
        resetGesturePreviewState()
        if !isFullscreen {
            resetContentLayer()
        }
        applyCornerRadius()
        if isFullscreen {
            applyPreviewVisual(scale: 1, alpha: window.alphaValue)
        }
    }
    
    private func applyCornerRadius() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = appStore.isFullscreenMode ? 0 : 30 * appStore.layoutScale
        contentView.layer?.masksToBounds = true
        contentView.layer?.allowsEdgeAntialiasing = true
        configurePreviewLayerGeometry()
    }

    private func applyGestureProgress(direction: GlobalPinchGestureDirection, progress: CGFloat) {
        guard let window else { return }
        let clamped = max(0, min(1, progress))
        if gesturePreviewMode == nil {
            gesturePreviewMode = window.isVisible ? .hiding : .showing
            gesturePreviewTargetRect = targetRectForCurrentScreen()
        }
        transitionPreviewModeIfNeeded(for: direction)
        guard let mode = gesturePreviewMode, let targetRect = gesturePreviewTargetRect else { return }
        let resolvedProgress = resolvedProgress(for: direction, progress: clamped)
        let smoothedProgress = smoothedPreviewProgress(for: mode, targetProgress: resolvedProgress)
        gesturePreviewProgress = smoothedProgress
        if smoothedProgress >= previewActivationProgress {
            gesturePreviewActivated = true
        }

        switch mode {
        case .showing:
            guard direction == .pinchIn else { return }
            guard gesturePreviewActivated else { return }
            if !window.isVisible {
                gesturePreviewMadeVisible = true
                prepareToShow()
                window.setFrame(targetRect, display: true)
                applyCornerRadius()
                applyPreviewVisual(scale: previewScale(for: smoothedProgress), alpha: previewAlpha(for: smoothedProgress))
                window.orderFrontRegardless()
                ensureSearchFieldFocusDuringShowGesture(window: window)
                return
            }
            ensureSearchFieldFocusDuringShowGesture(window: window)
            applyPreviewVisual(scale: previewScale(for: smoothedProgress), alpha: previewAlpha(for: smoothedProgress))
        case .hiding:
            guard direction == .pinchOut, window.isVisible else { return }
            guard gesturePreviewActivated else { return }
            if window.frame != targetRect {
                window.setFrame(targetRect, display: true)
            }
            let reversibleProgress = 1 - smoothedProgress
            applyPreviewVisual(scale: previewScale(for: reversibleProgress), alpha: previewAlpha(for: reversibleProgress))
        }
    }

    private func registerGestureCommit(_ action: GestureCommittedAction) {
        switch (gesturePreviewMode, action) {
        case (.showing, .show), (.hiding, .hide):
            gestureCommittedAction = action
        default:
            break
        }
    }

    private func finishGesturePreview() {
        guard let window else { return }
        defer { resetGesturePreviewState() }
        guard let mode = gesturePreviewMode, gesturePreviewTargetRect != nil else { return }
        guard gesturePreviewActivated else { return }

        switch mode {
        case .showing where shouldCompleteCurrentGesture():
            // Ensure the window gets focus immediately when the show animation starts
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NotificationCenter.default.post(name: .launchpadFocusSearchField, object: nil)
            animatePreviewVisual(toScale: 1, alpha: 1) {
                self.finalizeShownState()
            }
        case .showing:
            rollbackToHidden(window: window)
        case .hiding where shouldCompleteCurrentGesture():
            animatePreviewVisual(toScale: previewScale(for: 0), alpha: previewAlpha(for: 0)) {
                self.finalizeHiddenState()
            }
        case .hiding:
            rollbackToShown()
        }
    }

    private func cancelGesturePreview() {
        guard let window else { return }
        if let targetRect = gesturePreviewTargetRect {
            window.setFrame(targetRect, display: true)
            applyPreviewVisual(scale: 1, alpha: 1)
            if gesturePreviewMadeVisible {
                window.orderOut(nil)
                didHideWindow()
            }
        }
        resetGesturePreviewState()
    }

    private func resetGesturePreviewState() {
        gesturePreviewMode = nil
        gesturePreviewMadeVisible = false
        gesturePreviewTargetRect = nil
        gestureCommittedAction = nil
        gesturePreviewProgress = 0
        gestureContinuityProgress = nil
        gesturePreviewActivated = false
        gestureSearchFocusAssigned = false
    }

    private func resetContentLayer() {
        guard let contentLayer = window?.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.transform = CATransform3DIdentity
        contentLayer.opacity = 1
        CATransaction.commit()
    }

    private func animateLayerOpacity(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval, timing name: CAMediaTimingFunctionName, completion: (() -> Void)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: name)
        layer.opacity = to
        layer.add(animation, forKey: "launchnow.opacity")
        CATransaction.commit()
    }

    private func animatePreviewVisual(toScale scale: CGFloat, alpha: CGFloat, completion: (() -> Void)?) {
        guard appStore.isFullscreenMode else {
            completion?()
            return
        }
        guard let contentLayer = window?.contentView?.layer else {
            completion?()
            return
        }
        configurePreviewLayerGeometry()
        let duration: CFTimeInterval = 0.2
        let timingFunction = CAMediaTimingFunction(name: .easeOut)
        let currentOpacity = contentLayer.presentation()?.opacity ?? contentLayer.opacity
        let currentTransform = contentLayer.presentation()?.transform ?? contentLayer.transform
        let targetOpacity = Float(alpha)
        let targetTransform = CATransform3DMakeScale(scale, scale, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = currentOpacity
        opacityAnimation.toValue = targetOpacity
        opacityAnimation.duration = duration
        opacityAnimation.timingFunction = timingFunction

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = currentTransform
        transformAnimation.toValue = targetTransform
        transformAnimation.duration = duration
        transformAnimation.timingFunction = timingFunction

        contentLayer.opacity = targetOpacity
        contentLayer.transform = targetTransform
        contentLayer.add(opacityAnimation, forKey: "launchnow.opacity")
        contentLayer.add(transformAnimation, forKey: "launchnow.transform")
        CATransaction.commit()
    }

    private func rollbackToHidden(window: NSWindow) {
        guard gesturePreviewMadeVisible else { return }
        animatePreviewVisual(toScale: previewScale(for: 0), alpha: previewAlpha(for: 0)) {
            window.orderOut(nil)
            self.didHideWindow()
            self.applyPreviewVisual(scale: 1, alpha: 1)
            window.alphaValue = 1
        }
    }

    private func rollbackToShown() {
        animatePreviewVisual(toScale: 1, alpha: 1, completion: nil)
    }

    private func applyPreviewVisual(scale: CGFloat, alpha: CGFloat) {
        guard appStore.isFullscreenMode else { return }
        guard let contentLayer = window?.contentView?.layer else { return }
        configurePreviewLayerGeometry()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        contentLayer.opacity = Float(alpha)
        CATransaction.commit()
    }

    private func ensureSearchFieldFocusDuringShowGesture(window: NSWindow) {
        guard !gestureSearchFocusAssigned else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .launchpadFocusSearchField, object: nil)
        gestureSearchFocusAssigned = true
    }

    private func configurePreviewLayerGeometry() {
        guard let contentView = window?.contentView, let contentLayer = contentView.layer else { return }
        contentLayer.bounds = contentView.bounds
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.position = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }

    /// 全屏模式铺满鼠标所在的屏幕；窗口模式按「整体大小」在这块屏幕上居中
    private func targetRectForCurrentScreen() -> NSRect {
        guard let screen = getCurrentActiveScreen() ?? NSScreen.main else { return window?.frame ?? .zero }
        return appStore.isFullscreenMode ? screen.frame : centeredRect(for: screen)
    }

    private func transitionPreviewModeIfNeeded(for direction: GlobalPinchGestureDirection) {
        switch (gesturePreviewMode, direction) {
        case (.showing, .pinchOut):
            gesturePreviewMode = .hiding
            gestureCommittedAction = nil
            gestureContinuityProgress = currentPreviewProgress(for: .hiding)
        case (.hiding, .pinchIn):
            gesturePreviewMode = .showing
            gestureCommittedAction = nil
            gestureContinuityProgress = currentPreviewProgress(for: .showing)
        default:
            break
        }
    }

    private func resolvedProgress(for direction: GlobalPinchGestureDirection, progress: CGFloat) -> CGFloat {
        let continuityProgress = gestureContinuityProgress ?? 0
        let baseProgress: CGFloat
        switch (gestureCommittedAction, gesturePreviewMode, direction) {
        case (.show, .showing, .pinchIn), (.hide, .hiding, .pinchOut):
            baseProgress = 1
        default:
            baseProgress = progress
        }
        let resolved = max(baseProgress, continuityProgress)
        if baseProgress >= continuityProgress {
            gestureContinuityProgress = nil
        } else {
            gestureContinuityProgress = resolved
        }
        return resolved
    }

    private func shouldCompleteCurrentGesture() -> Bool {
        if let action = gestureCommittedAction {
            switch (gesturePreviewMode, action) {
            case (.showing, .show), (.hiding, .hide):
                return true
            default:
                break
            }
        }
        return gesturePreviewProgress >= gestureCompletionProgressThreshold
    }

    private func smoothedPreviewProgress(for mode: GesturePreviewMode, targetProgress: CGFloat) -> CGFloat {
        guard gesturePreviewActivated else { return targetProgress }
        let currentProgress = currentPreviewProgress(for: mode)
        if abs(targetProgress - currentProgress) < 0.02 {
            return targetProgress
        }
        return currentProgress + (targetProgress - currentProgress) * previewSmoothingFactor
    }

    private func currentPreviewProgress(for mode: GesturePreviewMode) -> CGFloat {
        let scale = currentPreviewScale()
        switch mode {
        case .showing:
            return max(0, min(1, (showStartScale - scale) / (showStartScale - 1)))
        case .hiding:
            let visibleProgress = max(0, min(1, (showStartScale - scale) / (showStartScale - 1)))
            return 1 - visibleProgress
        }
    }

    private func currentPreviewScale() -> CGFloat {
        guard let contentLayer = window?.contentView?.layer else { return 1 }
        let activeTransform = contentLayer.presentation()?.transform ?? contentLayer.transform
        return max(1, CGFloat(activeTransform.m11))
    }

    private func previewScale(for progress: CGFloat) -> CGFloat {
        showStartScale - (showStartScale - 1) * progress
    }

    private func previewAlpha(for progress: CGFloat) -> CGFloat {
        max(0, (progress - 0.12) / 0.88)
    }
    
    /// 这块屏幕上面板最高多高：「整体大小」100% 的 840；屏幕矮的话到可用区域的 92%（留点边，不贴菜单栏和程序坞）
    private func maxPanelHeight(for screen: NSScreen) -> CGFloat {
        let visibleFrame = screen.visibleFrame
        return min(Self.referenceHeight, visibleFrame.height * 0.92, visibleFrame.width * 0.92 / Self.windowAspect)
    }

    /// 窗口模式的面板大小：高 = 840 × 「整体大小」，宽按 7:6。屏幕放不下时只是这次缩小，不改设置
    private func panelSize(for screen: NSScreen) -> NSSize {
        let height = min(Self.referenceHeight * CGFloat(appStore.panelScale), maxPanelHeight(for: screen)).rounded()
        return NSSize(width: (height * Self.windowAspect).rounded(), height: height)
    }

    /// 按「整体大小」在屏幕去掉菜单栏和程序坞后的区域里居中
    private func centeredRect(for screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let size = panelSize(for: screen)
        return NSRect(x: (visibleFrame.midX - size.width / 2).rounded(),
                      y: (visibleFrame.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// 鼠标所在的屏幕。鼠标在屏幕最上面一行时 y 正好等于 frame.maxY，contains 不算在内：
    /// 上下叠放的两块屏，交界处会算到上面那块，最顶上一行哪块都不算。NSMouseInRect 按鼠标的规矩算。
    /// 万一哪块都不算（比如正好在最下面一行），取离鼠标最近的那块，而不是有焦点窗口的那块
    private func getCurrentActiveScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        if let hit = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return hit
        }
        return screens.min { distance(from: mouse, to: $0.frame) < distance(from: mouse, to: $1.frame) }
    }

    private func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
    
    private func resolveScreen(for window: NSWindow) -> NSScreen? {
        // 优先：窗口中心点实际所在的屏幕
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        // 其次：window.screen 仍有效
        if let ws = window.screen, NSScreen.screens.contains(ws) {
            return ws
        }
        // 兜底：主屏幕
        return NSScreen.main
    }
    
    @objc private func handleScreenParametersDidChange() {
        guard let window = window else { return }
        guard let screen = resolveScreen(for: window) else { return }
        // 换了屏幕、分辨率、程序坞：重新居中；屏幕放不下时只是临时缩小，不改「整体大小」
        window.setFrame(appStore.isFullscreenMode ? screen.frame : centeredRect(for: screen), display: true)
        refreshSettingsMaxHeight()
    }

    /// 拖窗口边缘：范围和「整体大小」滑块一样，最小 60%，最大 100%（屏幕放不下时到屏幕放得下的大小）
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minSize = minimumContentSize
        let maxHeight = (sender.screen ?? getCurrentActiveScreen()).map(maxPanelHeight) ?? Self.referenceHeight
        let maxSize = NSSize(width: (maxHeight * Self.windowAspect).rounded(), height: maxHeight.rounded())
        let contentSize = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let clamped = NSSize(width: min(max(contentSize.width, minSize.width), maxSize.width),
                             height: min(max(contentSize.height, minSize.height), maxSize.height))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: clamped)).size
    }

    /// 拖完窗口边缘：记成「整体大小」，设置里的滑块跟着变
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window, !appStore.isFullscreenMode else { return }
        appStore.panelScale = AppStore.clampedPanelScale(Double(window.frame.height / Self.referenceHeight))
    }

    func windowDidMove(_ notification: Notification) {
        refreshSettingsMaxHeight()
    }

    func windowDidResize(_ notification: Notification) {
        refreshLayoutScale()
        refreshSettingsMaxHeight()
        guard !appStore.isFullscreenMode, !isAnimatingWindowTransition else { return }
        guard let window = notification.object as? NSWindow, window.isVisible else { return }
        guard let screen = window.screen ?? getCurrentActiveScreen() else { return }

        // 缩放后重新居中窗口
        guard !isRecentering else { return }
        isRecentering = true
        defer { isRecentering = false }
        
        let visibleFrame = screen.visibleFrame
        let windowFrame = window.frame
        // 计算居中位置（注意 AppKit 坐标系 y 轴向上）
        let centeredX = visibleFrame.midX - windowFrame.width / 2
        let centeredY = visibleFrame.midY - windowFrame.height / 2
        // 确保不超出屏幕边界
        let clampedX = min(max(visibleFrame.minX, centeredX), visibleFrame.maxX - windowFrame.width)
        let clampedY = min(max(visibleFrame.minY, centeredY), visibleFrame.maxY - windowFrame.height)
        
        if abs(windowFrame.origin.x - clampedX) > 1 || abs(windowFrame.origin.y - clampedY) > 1 {
            window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        }
    }
    
    func windowDidResignKey(_ notification: Notification) { autoHideIfNeeded() }
    func windowDidResignMain(_ notification: Notification) { autoHideIfNeeded() }
    private func autoHideIfNeeded() {
        guard !appStore.isSetting, !appStore.isPresentingAlert, !isAnimatingWindowTransition else { return }
        requestHideWindow()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window?.isVisible == true {
            requestHideWindow()
        } else {
            requestShowWindow()
        }
        return false
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 面板开着时退出（设置里的「退出」）：输入法切回去
        inputSource.restore()
    }
    
}
