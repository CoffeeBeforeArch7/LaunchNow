import AppKit
import AVFoundation
import CoreImage

/// 打开 LaunchNow 时铺在它下面、盖住其它窗口的整屏「模糊墙纸」，像原生启动台；收起时一起淡出。
/// 桌面上只剩 LaunchNow，但不去隐藏或最小化别的 App：那样会打乱台前调度的排布，收起后也恢复不回原样。
/// 墙纸取各屏当前桌面实际用的那张（航拍墙纸取视频第一帧），模糊后和屏幕上那一帧看不出差别
final class DesktopBackdrop {
    /// 点了遮罩（LaunchNow 面板以外的地方）
    var onClick: (() -> Void)?

    private var windows: [CGDirectDisplayID: BackdropWindow] = [:]
    /// 处理好的模糊墙纸，按墙纸文件缓存
    private var images: [URL: CGImage] = [:]
    private var loading: Set<URL> = []
    private var isShown = false

    /// 预先把各屏当前墙纸处理好（启动、切换桌面时调用），打开时不用等
    func prepare() {
        for screen in NSScreen.screens {
            if let url = WallpaperSource.url(for: screen) {
                load(url)
            }
        }
    }

    /// 铺到所有屏上，放在 LaunchNow 窗口正下方
    func show(below window: NSWindow, fadeDuration: TimeInterval) {
        isShown = true
        let liveDisplays = Set(NSScreen.screens.map(\.displayID))
        for (displayID, stale) in windows where !liveDisplays.contains(displayID) {
            stale.orderOut(nil)
            windows[displayID] = nil
        }
        for screen in NSScreen.screens {
            let backdropWindow = self.window(for: screen)
            backdropWindow.setFrame(screen.frame, display: false)
            let url = WallpaperSource.url(for: screen)
            backdropWindow.wallpaperURL = url
            backdropWindow.backdropView.setImage(url.flatMap { images[$0] }, animated: false)
            if let url, images[url] == nil {
                load(url)
            }
            if !backdropWindow.isVisible {
                backdropWindow.alphaValue = 0
            }
            backdropWindow.order(.below, relativeTo: window.windowNumber)
        }
        fade(to: 1, duration: fadeDuration)
    }

    func hide(fadeDuration: TimeInterval) {
        guard isShown else { return }
        isShown = false
        fade(to: 0, duration: fadeDuration)
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval) {
        let targets = Array(windows.values)
        let finish = { [weak self] in
            // 淡出途中又打开了就别收起
            guard let self, !self.isShown else { return }
            targets.forEach { $0.orderOut(nil) }
        }
        guard duration > 0 else {
            targets.forEach { $0.alphaValue = alpha }
            if alpha == 0 { finish() }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .default)
            targets.forEach { $0.animator().alphaValue = alpha }
        }, completionHandler: alpha == 0 ? finish : nil)
    }

    private func window(for screen: NSScreen) -> BackdropWindow {
        if let existing = windows[screen.displayID] {
            return existing
        }
        let backdropWindow = BackdropWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdropWindow.isReleasedWhenClosed = false
        backdropWindow.isOpaque = false
        backdropWindow.backgroundColor = .clear
        backdropWindow.hasShadow = false
        backdropWindow.animationBehavior = .none
        // 和 LaunchNow 窗口同一层，靠 order(.below:) 排在它正下方：这样也能盖住别的 App 的置顶小窗
        backdropWindow.level = .floating
        backdropWindow.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        backdropWindow.backdropView.onClick = { [weak self] in self?.onClick?() }
        windows[screen.displayID] = backdropWindow
        return backdropWindow
    }

    private func load(_ url: URL) {
        guard images[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)
        DispatchQueue.global(qos: .utility).async {
            let image = Self.makeBackdropImage(from: url)
            DispatchQueue.main.async {
                self.loading.remove(url)
                guard let image else { return }
                self.images[url] = image
                // 打开时还没处理好的，好了再换上
                for backdropWindow in self.windows.values where backdropWindow.wallpaperURL == url {
                    backdropWindow.backdropView.setImage(image, animated: backdropWindow.isVisible)
                }
            }
        }
    }

    // MARK: - 墙纸处理（后台线程）

    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// 处理成这么宽就够了：模糊之后再放大看不出差别，一张只占约 2MB
    nonisolated private static let workingWidth = 960

    nonisolated private static func makeBackdropImage(from url: URL) -> CGImage? {
        let source = url.pathExtension.lowercased() == "mov" ? firstFrame(ofVideo: url) : downsampledImage(at: url)
        guard let source else { return nil }
        let input = CIImage(cgImage: source)
        // 模糊程度和原生启动台相当：约为画面宽度的 2%
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(source.width) * 0.02)
            .cropped(to: input.extent)
        return ciContext.createCGImage(blurred, from: input.extent)
    }

    nonisolated private static func firstFrame(ofVideo url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: workingWidth, height: workingWidth)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let done = DispatchSemaphore(value: 0)
        let result = FrameBox()
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            result.image = image
            done.signal()
        }
        done.wait()
        return result.image
    }

    private final class FrameBox: @unchecked Sendable {
        nonisolated(unsafe) var image: CGImage?
    }

    nonisolated private static func downsampledImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingWidth
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - 遮罩窗口

private final class BackdropWindow: NSWindow {
    let backdropView = BackdropView()
    /// 这块屏现在用的墙纸，后台处理好了按它对号入座
    var wallpaperURL: URL?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        contentView = backdropView
    }

    // 点遮罩不抢 LaunchNow 面板的焦点
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BackdropView: NSView {
    var onClick: (() -> Void)?
    private let imageLayer = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // 墙纸还没处理好时先用半透明深色垫着
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.55).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(imageLayer)
        // 压暗一点，让面板更突出
        let dimLayer = CALayer()
        dimLayer.backgroundColor = NSColor(white: 0, alpha: 0.12).cgColor
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(dimLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: CGImage?, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            let transition = CATransition()
            transition.duration = 0.2
            imageLayer.add(transition, forKey: "contents")
        }
        imageLayer.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - 当前桌面用的是哪张墙纸

/// 系统的公开接口只给得出静态图片墙纸；航拍墙纸是视频、而且每个桌面（Space）可以不同，
/// 这里读壁纸设置（~/Library/Application Support/com.apple.wallpaper/Store/Index.plist），
/// 配合私有接口拿到各屏当前桌面的 UUID，找出实际在用的那一张
enum WallpaperSource {
    private static let aerialsRoot = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd")

    static func url(for screen: NSScreen) -> URL? {
        let displayUUID = displayUUIDString(screen.displayID)
        let spaceUUID = currentSpaceUUID(displayUUID: displayUUID)
        if let choice = desktopChoice(spaceUUID: spaceUUID, displayUUID: displayUUID),
           let url = file(for: choice) {
            return url
        }
        // 系统默认墙纸、普通图片墙纸等
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    private static func displayUUIDString(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// 这块屏现在停在哪个桌面
    private static func currentSpaceUUID(displayUUID: String?) -> String? {
        typealias MainConnectionID = @convention(c) () -> Int32
        typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connectionSymbol = dlsym(skyLight, "SLSMainConnectionID"),
              let spacesSymbol = dlsym(skyLight, "SLSCopyManagedDisplaySpaces") else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: MainConnectionID.self)()
        let copySpaces = unsafeBitCast(spacesSymbol, to: CopyManagedDisplaySpaces.self)
        guard let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        // 关掉「显示器具有单独的空间」时只有一项，标识是 "Main"
        let display = displays.first { ($0["Display Identifier"] as? String) == displayUUID }
            ?? displays.first { ($0["Display Identifier"] as? String) == "Main" }
        return (display?["Current Space"] as? [String: Any])?["uuid"] as? String
    }

    /// 按优先级找设置：该桌面在这块屏上的 → 该桌面的默认 → 这块屏的 → 所有桌面和屏幕的
    private static func desktopChoice(spaceUUID: String?, displayUUID: String?) -> [String: Any]? {
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: storeURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let space = spaceUUID.flatMap { (root["Spaces"] as? [String: Any])?[$0] as? [String: Any] }
        let candidates: [Any?] = [
            displayUUID.flatMap { (space?["Displays"] as? [String: Any])?[$0] },
            space?["Default"],
            displayUUID.flatMap { (root["Displays"] as? [String: Any])?[$0] },
            root["AllSpacesAndDisplays"]
        ]
        for candidate in candidates {
            guard let desktop = (candidate as? [String: Any])?["Desktop"] as? [String: Any],
                  let content = desktop["Content"] as? [String: Any],
                  let choice = (content["Choices"] as? [[String: Any]])?.first else { continue }
            return choice
        }
        return nil
    }

    /// 设置项对应的文件：航拍取视频（没下载就用预览图），图片墙纸取图片；其它（系统默认等）交给系统接口
    private static func file(for choice: [String: Any]) -> URL? {
        let provider = choice["Provider"] as? String ?? ""
        let configuration = (choice["Configuration"] as? Data).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil)
        }
        if provider.hasSuffix(".aerials"),
           let assetID = (configuration as? [String: Any])?["assetID"] as? String {
            let customer = aerialsRoot.appendingPathComponent("Customer")
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: customer.path)) ?? []
            for folder in folders.sorted() {
                let video = customer.appendingPathComponent(folder).appendingPathComponent("\(assetID).mov")
                if FileManager.default.fileExists(atPath: video.path) {
                    return video
                }
            }
            let preview = aerialsRoot.appendingPathComponent("snapshots/asset-preview-\(assetID).jpg")
            return FileManager.default.fileExists(atPath: preview.path) ? preview : nil
        }
        if provider.hasSuffix(".image") {
            return fileURL(in: configuration)
        }
        return nil
    }

    /// 在设置里找第一个存在的本地文件地址
    private static func fileURL(in value: Any?) -> URL? {
        if let string = value as? String, string.hasPrefix("file://"),
           let url = URL(string: string), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                if let url = fileURL(in: dictionary[key]) { return url }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let url = fileURL(in: item) { return url }
            }
        }
        return nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
