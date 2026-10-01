import Carbon
import Foundation

/// Registering 知音 with the Text Input Sources service.
enum InputSource {
    static let bundleID = "com.zhiyin.inputmethod"
    static let modeID = "com.zhiyin.inputmethod.Hans"

    static func sources() -> [TISInputSource] {
        (TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    static func identifier(_ source: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func current() -> String? {
        identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    /// Registers the bundle and enables every 知音 source. Returns how many.
    @discardableResult
    static func register(bundle: URL) -> Int {
        TISRegisterInputSource(bundle as CFURL)
        var enabled = 0
        for s in sources() {
            guard let id = identifier(s), id.hasPrefix(bundleID) else { continue }
            TISEnableInputSource(s)
            enabled += 1
        }
        return enabled
    }

    @discardableResult
    static func select(_ wanted: String) -> Bool {
        for s in sources() where identifier(s) == wanted {
            return TISSelectInputSource(s) == noErr
        }
        return false
    }

    static func disable() {
        for s in sources() {
            guard let id = identifier(s), id.hasPrefix(bundleID) else { continue }
            TISDisableInputSource(s)
        }
    }
}
