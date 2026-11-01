import Carbon.HIToolbox
import Foundation

/// "ctrl+opt+space" 形式の文字列で表すグローバルホットキー(Carbon の RegisterEventHotKey は権限が要らない)
struct HotkeySpec: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Cmd+Shift+Space は Electron 版の設定、Cmd+Shift+P は ZMK の j+k+e が送るキー
    static let defaults = [
        HotkeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
        HotkeySpec(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey)),
    ]

    private static let keys: [String: Int] = [
        "space": kVK_Space, "return": kVK_Return, "escape": kVK_Escape,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11,
        "f12": kVK_F12,
    ]

    /// 解釈できない文字列は nil(黙って既定値へ落とさず、呼び出し側が起動時にエラーにする)
    init?(_ text: String) {
        var mods: UInt32 = 0
        var key: UInt32?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "opt", "alt", "option": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            default:
                guard key == nil, let code = Self.keys[part] else { return nil }
                key = UInt32(code)
            }
        }
        guard let key, mods != 0 else { return nil }
        self.keyCode = key
        self.modifiers = mods
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

final class GlobalHotkey {
    var onPress: (() -> Void)?
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 他のアプリが同じ組み合わせを使用中だと登録に失敗する
    init?(_ spec: HotkeySpec) {
        id = Self.nextID
        Self.nextID += 1
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                // 登録した全ホットキーのイベントが全ハンドラへ届く。自分宛てでなければ「未処理」で返して次のハンドラへ渡す
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                let me = Unmanaged<GlobalHotkey>.fromOpaque(userData!).takeUnretainedValue()
                guard pressed.id == me.id else { return OSStatus(eventNotHandledErr) }
                me.onPress?()
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x504C_4E45), id: id)
        let registered = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
