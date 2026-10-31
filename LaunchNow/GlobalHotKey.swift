import Carbon.HIToolbox
import Foundation

// MARK: - 全局快捷键（默认 ⌘空格）
//
// 用 Carbon 的 RegisterEventHotKey：不需要辅助功能权限。
// ⌘空格默认属于聚焦搜索，要先在 系统设置 ▸ 键盘 ▸ 键盘快捷键 ▸ 聚焦 里关掉它。

final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    /// 注册快捷键，按下时在主线程执行 action。成功返回 true。
    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_Space),
                  modifiers: UInt32 = UInt32(cmdKey),
                  action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // Carbon 在主线程派发热键事件
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard status == noErr else {
            NSLog("LaunchNow: InstallEventHandler failed (\(status))")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4E_4857), id: 1) // 'LNHW'
        let result = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if result != noErr {
            NSLog("LaunchNow: RegisterEventHotKey failed (\(result)); is the shortcut taken?")
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
