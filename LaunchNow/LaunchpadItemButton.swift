import SwiftUI
import AppKit
import Combine
// Shared animations

struct LaunchpadItemButton: View {
    let item: LaunchpadItem
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let isSelected: Bool
    let showAppNameBelowIcon: Bool
    var shouldAllowHover: Bool = true
    var externalScale: CGFloat? = nil
    /// 「整体大小」的缩放比例：间距、名字字号跟着缩（图标边长由外面按格子算好）
    var scale: CGFloat = 1
    let onTap: () -> Void
    let onDoubleClick: (() -> Void)?
    
    @State private var isHovered = false
    @State private var lastTapTime = Date.distantPast
    @State private var folderIconRefreshToken: UInt = 0
    @Environment(\.displayScale) private var displayScale
    private let doubleTapThreshold: TimeInterval = 0.3
    
    private var effectiveScale: CGFloat {
        if let s = externalScale { return s }
        return (isHovered && shouldAllowHover) ? 1.2 : 1.0
    }
    
    private var isFolderIcon: Bool {
        if case .folder = item { return true }
        return false
    }

    // Memoized icon to avoid recomputing on every body invocation
    @inline(__always)
    private func resolveIcon() -> NSImage {
        switch item {
        case .app(let app):
            return CrispIcon.image(app.displayIcon, id: app.url.path, side: iconSize, scale: displayScale)
        case .folder(let folder):
            return folder.icon(of: iconSize)
        case .empty:
            return item.icon
        }
    }

    init(
        item: LaunchpadItem,
        iconSize: CGFloat = 72,
        labelWidth: CGFloat = 80,
        isSelected: Bool = false,
        showAppNameBelowIcon: Bool = true,
        shouldAllowHover: Bool = true,
        externalScale: CGFloat? = nil,
        scale: CGFloat = 1,
        onTap: @escaping () -> Void,
        onDoubleClick: (() -> Void)? = nil) {
            self.item = item
            self.iconSize = iconSize
            self.labelWidth = labelWidth
            self.isSelected = isSelected
            self.showAppNameBelowIcon = showAppNameBelowIcon
            self.shouldAllowHover = shouldAllowHover
            self.externalScale = externalScale
            self.scale = scale
            self.onTap = onTap
            self.onDoubleClick = onDoubleClick
        }

    var body: some View {
        _ = folderIconRefreshToken
        let renderedIcon = resolveIcon()
        return Button(action: handleTap) {
            VStack(spacing: 8 * scale) {
                ZStack {
                    if isFolderIcon {   
                        RoundedRectangle(cornerRadius: iconSize * 0.2)
                            .foregroundStyle(Color.clear)
                            .frame(width: iconSize * 0.8, height: iconSize * 0.8)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: iconSize * 0.2))
                            .shadow(radius: 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: iconSize * 0.2)
                                    .stroke(Color.foundary.opacity(0.18), lineWidth: 1)
                            )
                    }
                    
                    Image(nsImage: renderedIcon)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: iconSize, height: iconSize)
                }
                .contentShape(Rectangle())
                .scaleEffect(isSelected ? 1.2 : effectiveScale)
                .animation(LNAnimations.easeInOut, value: isHovered || isSelected)

                if showAppNameBelowIcon {
                    AppNameLabel(name: item.name, width: labelWidth, fontScale: AppStore.textScale(for: scale))
                        .foregroundStyle(.primary)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(8 * scale)
        .onHover { hovering in
            if shouldAllowHover {
                isHovered = hovering
            } else if isHovered {
                isHovered = false
            }
        }
        .onChange(of: shouldAllowHover) {
            if !shouldAllowHover, isHovered {
                isHovered = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: FolderInfo.folderIconDidUpdate)) { notification in
            guard case .folder(let folder) = item,
                  let updatedFolderID = notification.object as? String,
                  updatedFolderID == folder.id else { return }
            folderIconRefreshToken &+= 1
        }
    }
    
    private func handleTap() {
        let now = Date()
        let timeSinceLastTap = now.timeIntervalSince(lastTapTime)
        
        if timeSinceLastTap <= doubleTapThreshold, let doubleClick = onDoubleClick {
            // 双击
            doubleClick()
        } else {
            // 单击
            onTap()
        }
        
        lastTapTime = now
    }
}

// Equatable conformance intentionally excludes closures (onTap, onDoubleClick).
// This allows SwiftUI to skip body re-evaluation when only scroll offset changes,
// while still re-rendering when any visible property actually changes.
extension LaunchpadItemButton: Equatable {
    private static func isVisuallySameItem(_ lhs: LaunchpadItem, _ rhs: LaunchpadItem) -> Bool {
        switch (lhs, rhs) {
        case let (.app(lApp), .app(rApp)):
            return lApp.id == rApp.id &&
                lApp.name == rApp.name &&
                lApp.icon === rApp.icon
        case let (.folder(lFolder), .folder(rFolder)):
            // Folder icon and title depend on folder name + contained apps.
            return lFolder.id == rFolder.id &&
                lFolder.name == rFolder.name &&
                lFolder.apps.count == rFolder.apps.count &&
                zip(lFolder.apps, rFolder.apps).allSatisfy { lApp, rApp in
                    lApp.id == rApp.id &&
                    lApp.name == rApp.name &&
                    lApp.icon === rApp.icon
                }
        case let (.empty(lToken), .empty(rToken)):
            return lToken == rToken
        default:
            return false
        }
    }

    static func == (lhs: LaunchpadItemButton, rhs: LaunchpadItemButton) -> Bool {
        isVisuallySameItem(lhs.item, rhs.item) &&
        lhs.iconSize == rhs.iconSize &&
        lhs.labelWidth == rhs.labelWidth &&
        lhs.isSelected == rhs.isSelected &&
        lhs.showAppNameBelowIcon == rhs.showAppNameBelowIcon &&
        lhs.shouldAllowHover == rhs.shouldAllowHover &&
        lhs.externalScale == rhs.externalScale &&
        lhs.scale == rhs.scale
    }
}

/// 图标下方的名字，尽量显示完整：单行，放不下就把字号缩小（最小到 65%）。
/// 不折成两行：行高按一行字算，第二行会被下一排图标压住
struct AppNameLabel: View {
    let name: String
    let width: CGFloat
    /// 字号缩放（「整体大小」，最小 0.85，见 AppStore.textScale）
    var fontScale: CGFloat = 1

    var body: some View {
        Text(name)
            .font(.system(size: 13 * fontScale, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .allowsTightening(true)
            .multilineTextAlignment(.center)
            // 高度按字号自然撑开，只有宽度放不下才缩小；不然格子偏矮时短名字也会被缩小
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width)
    }
}
