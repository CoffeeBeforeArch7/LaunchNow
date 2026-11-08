import Carbon.HIToolbox

/// 打开面板时切到英文键盘（U.S. / ABC），打字直接进搜索框、不用先关中文输入法（搜中文名用拼音，见 PinyinSearch）；
/// 收起时切回打开前的输入法
final class InputSourceSwitcher {
    /// 打开前的输入法；没切换过时为 nil
    private var previous: TISInputSource?

    /// 当前是拼音等不能直接打英文的输入法时，记下它并切到英文键盘
    func switchToEnglish() {
        guard previous == nil else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard !Self.bool(current, kTISPropertyInputSourceIsASCIICapable),
              let english = Self.englishKeyboard(),
              TISSelectInputSource(english) == noErr else { return }
        previous = current
    }

    /// 切回打开前的输入法。在面板还是焦点时调最好：中文输入法要等焦点变一次才真正生效，切回后焦点马上交给别的 App 正好
    func restore() {
        guard let previous else { return }
        self.previous = nil
        TISSelectInputSource(previous)
    }

    /// 输入法菜单里最近用过的英文键盘；它被关掉了就取已启用的第一个英文键盘
    private static func englishKeyboard() -> TISInputSource? {
        let recent = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        if bool(recent, kTISPropertyInputSourceIsEnabled), bool(recent, kTISPropertyInputSourceIsSelectCapable) {
            return recent
        }
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as CFString,
            kTISPropertyInputSourceIsASCIICapable: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        let enabled = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]
        return enabled?.first
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}
