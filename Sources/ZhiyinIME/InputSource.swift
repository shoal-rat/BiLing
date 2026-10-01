import Carbon
import Foundation

/// Registering 知音 with the Text Input Sources service.
enum InputSource {
    static let bundleID = "com.zhiyin.inputmethod.Zhiyin"
    static let modeID = "com.zhiyin.inputmethod.Zhiyin.Hans"

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

    /// Registers the bundle and enables the 知音 input *mode* (never the
    /// parent method: enabling both lists 知音 twice in the input menu).
    /// The Text Input Sources service indexes a new bundle asynchronously, so
    /// this waits up to `timeout` for the mode to appear. Returns how many
    /// sources were enabled.
    @discardableResult
    static func register(bundle: URL, timeout: TimeInterval = 8) -> Int {
        let status = TISRegisterInputSource(bundle as CFURL)
        if status != noErr {
            FileHandle.standardError.write(Data("TISRegisterInputSource: \(status)\n".utf8))
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for s in sources() where identifier(s) == modeID {
                return TISEnableInputSource(s) == noErr ? 1 : 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        let seen = sources().compactMap(identifier).filter { $0.contains("zhiyin") }
        FileHandle.standardError.write(Data("知音's input mode did not appear (saw: \(seen)).\n".utf8))
        return 0
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
