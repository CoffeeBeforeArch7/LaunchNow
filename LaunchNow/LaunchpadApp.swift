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
    private let minimumContentSize = NSSize(width: 700, height: 600)
    /// 窗口宽高比 7:6：7 列 5 行、带名字的网格正好是这个比例，图标能放大又不挤
    private static let windowAspect: CGFloat = 7.0 / 6.0
    /// 打开时铺在下面、盖住其它窗口的模糊墙纸
    private let backdrop = DesktopBackdrop()
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
    private static let windowFrameDefaultsKey = "savedWindowFrame"
    
    private var savedWindowFrame: NSRect? {
        get {
            guard let dict = UserDefaults.standard.dictionary(forKey: Self.windowFrameDefaultsKey) else { return nil }
            guard let x = dict["x"] as? CGFloat,
                  let y = dict["y"] as? CGFloat,
                  let w = dict["width"] as? CGFloat,
                  let h = dict["height"] as? CGFloat else { return nil }
            return NSRect(x: x, y: y, width: w, height: h)
        }
        set {
            guard let rect = newValue else {
                UserDefaults.standard.removeObject(forKey: Self.windowFrameDefaultsKey)
                return
            }
            let dict: [String: CGFloat] = [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.width,
                "height": rect.height
            ]
            UserDefaults.standard.set(dict, forKey: Self.windowFrameDefaultsKey)
        }
    }
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
        // 点遮罩（面板以外）收起；和失去焦点自动收起同样的条件：设置、确认框开着时不收
        backdrop.onClick = { [weak self] in self?.autoHideIfNeeded() }
        backdrop.prepare()
        // 换了桌面（各桌面墙纸可以不同）就提前把那张墙纸处理好
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.backdrop.prepare()
        }
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

    /// 第 2 版布局：窗口按屏幕变大、改成 7:6，图标随之变大。旧版存的窗口尺寸和图标缩放作废一次
    private func migrateWindowLayoutIfNeeded() {
        let key = "windowLayoutVersion"
        guard UserDefaults.standard.integer(forKey: key) < 2 else { return }
        savedWindowFrame = nil
        appStore.iconScale = 1.0
        UserDefaults.standard.set(2, forKey: key)
    }

    /// 收起并打开 App（或系统设置等网址）：焦点交给新打开的那个，不切回之前的 App
    func hideAndOpen(_ url: URL) {
        refocusPreviousOnHide = false
        requestHideWindow {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开前调用：记下当前在用的 App
    private func rememberFrontmostApp() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = front
    }

    /// 窗口收起后：撤掉遮罩；按 Esc / ⌥空格 / 点遮罩收起时把焦点还给之前的 App
    /// （点了别的 App 或打开了 App 的，焦点已经在那边，不用还）
    private func didHideWindow() {
        backdrop.hide(fadeDuration: 0)
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
        
        // 非全屏模式下：加载上次保存的窗口尺寸；全屏模式使用屏幕尺寸
        let rect: NSRect
        if !appStore.isFullscreenMode {
            rect = centeredRect(for: screen, savedFrame: savedWindowFrame)
        } else {
            rect = calculateContentRect(for: screen)
        }
        
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
        
        applyCornerRadius()
        applyPreviewVisual(scale: 1, alpha: 1)
        window?.alphaValue = 1
        
        // 设置等比缩放的参考内容尺寸（非全屏模式下使用实际窗口大小，而非计算默认值）
        if !appStore.isFullscreenMode {
            let refSize = rect.size
            appStore.referenceContentSize = refSize
        }
    }
    
    private func finalizeShownState() {
        guard let window = window else { return }
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        resetGesturePreviewState()
        // 恢复保存的窗口 frame，或使用默认大小
        let rect: NSRect
        if !appStore.isFullscreenMode {
            rect = centeredRect(for: screen, savedFrame: savedWindowFrame)
        } else {
            rect = screen.frame
        }
        window.setFrame(rect, display: true)
        applyCornerRadius()
        applyPreviewVisual(scale: 1, alpha: 1)
        window.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        lastShowAt = Date()
        NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)
        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
        // 手势打开不经过 performShowTransition，在这里补上
        backdrop.show(below: window, fadeDuration: 0)
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
        // 隐藏前保存窗口 frame（非全屏模式下记住用户调整的大小和位置）
        if let window = window, !appStore.isFullscreenMode {
            savedWindowFrame = window.frame
        }
        resetGesturePreviewState()
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
        // 在隐藏前立即保存窗口 frame（确保任何隐藏路径都能记住尺寸）
        if !appStore.isFullscreenMode {
            savedWindowFrame = window.frame
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
        rememberFrontmostApp()

        let targetRect = targetRectForCurrentScreen()

        window.setFrame(targetRect, display: true)
        applyCornerRadius()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
        NotificationCenter.default.post(name: .launchpadFocusSearchField, object: nil)
        // 桌面上只留 LaunchNow：下面铺一层模糊墙纸盖住其它窗口，和面板一起淡入
        backdrop.show(below: window, fadeDuration: 0.15)

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
        // 遮罩和面板一起淡出
        backdrop.hide(fadeDuration: appStore.isFullscreenMode ? 0.2 : 0.15)

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
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        window.setFrame(isFullscreen ? screen.frame : calculateContentRect(for: screen), display: true)
        window.hasShadow = !isFullscreen
        window.contentAspectRatio = isFullscreen ? NSSize(width: 0, height: 0) : NSSize(width: 7, height: 6)
        // 切换模式时更新 styleMask：非全屏模式下允许边缘拖拽调整大小
        let newStyleMask: NSWindow.StyleMask = isFullscreen
            ? [.borderless, .fullSizeContentView]
            : [.borderless, .fullSizeContentView, .resizable]
        window.styleMask = newStyleMask
        // 切换模式时重置等比缩放参考尺寸
        if !isFullscreen {
            let refSize = calculateContentRect(for: screen).size
            appStore.referenceContentSize = refSize
        }
        // 切换全屏时清除保存的 frame，切换窗口模式时重置参考尺寸
        if isFullscreen {
            savedWindowFrame = nil
        }
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
        contentView.layer?.cornerRadius = appStore.isFullscreenMode ? 0 : 30
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
                rememberFrontmostApp()
                backdrop.show(below: window, fadeDuration: 0.15)
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
            backdrop.hide(fadeDuration: 0.2)
            animatePreviewVisual(toScale: previewScale(for: 0), alpha: previewAlpha(for: 0)) {
                self.finalizeHiddenState()
            }
        case .hiding:
            rollbackToShown()
        }
    }

    private func cancelGesturePreview() {
        guard let window else { return }
        // 手势取消时隐藏窗口，也需要保存 frame
        if !appStore.isFullscreenMode, window.isVisible {
            savedWindowFrame = window.frame
        }
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
        // 回滚到隐藏状态时保存 frame
        if !appStore.isFullscreenMode {
            savedWindowFrame = window.frame
        }
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

    private func targetRectForCurrentScreen() -> NSRect {
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        if appStore.isFullscreenMode {
            return screen.frame
        }
        // 非全屏模式下，保留保存的窗口尺寸，在当前屏幕居中
        return centeredRect(for: screen, savedFrame: savedWindowFrame)
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
    
    private func calculateContentRect(for screen: NSScreen) -> NSRect {
        centeredRect(for: screen, savedFrame: nil)
    }

    /// 默认窗口：高约占可用高度的 84%（最高 880pt），宽按 7:6（1920×1080 的屏上约 980×840）
    private func defaultWindowSize(for screen: NSScreen) -> NSSize {
        let visibleFrame = screen.visibleFrame
        var height = min(visibleFrame.height * 0.84, 880)
        if height * Self.windowAspect > visibleFrame.width * 0.9 {
            height = visibleFrame.width * 0.9 / Self.windowAspect
        }
        height = max(height, minimumContentSize.height).rounded()
        return NSSize(width: (height * Self.windowAspect).rounded(), height: height)
    }

    /// 保留保存的窗口尺寸（没有就用默认尺寸），在当前屏幕去掉菜单栏和程序坞后的区域里居中；放不下就等比缩小
    private func centeredRect(for screen: NSScreen, savedFrame: NSRect?) -> NSRect {
        let visibleFrame = screen.visibleFrame
        var size = savedFrame?.size ?? defaultWindowSize(for: screen)
        let fit = min(1, visibleFrame.width / size.width, visibleFrame.height / size.height)
        size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        return NSRect(x: (visibleFrame.midX - size.width / 2).rounded(),
                      y: (visibleFrame.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
    
    private func getCurrentActiveScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
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
        
        if appStore.isFullscreenMode {
            window.setFrame(screen.frame, display: true)
            return
        }
        
        let targetRect = centeredRect(for: screen, savedFrame: savedWindowFrame)
        window.setFrame(targetRect, display: true)
        savedWindowFrame = targetRect
    }
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minSize = minimumContentSize
        let contentSize = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let clamped = NSSize(width: max(contentSize.width, minSize.width), height: max(contentSize.height, minSize.height))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: clamped)).size
    }
    
    func windowDidResize(_ notification: Notification) {
        guard !appStore.isFullscreenMode, !isAnimatingWindowTransition else { return }
        guard let window = notification.object as? NSWindow, window.isVisible else { return }
        guard let screen = window.screen ?? getCurrentActiveScreen() else { return }
        
        // 用户手动调整窗口尺寸后，立即保存 frame（记住用户调整的大小）
        if !isRecentering {
            savedWindowFrame = window.frame
        }
        
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
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 应用退出前保存当前窗口尺寸
        if let window = window, !appStore.isFullscreenMode, window.isVisible {
            savedWindowFrame = window.frame
        }
        return .terminateNow
    }
    
}
