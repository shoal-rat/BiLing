import Carbon
import Foundation

enum InputSourceRegistration {
    static let bundleIdentifier = "com.biling.inputmethod.BiLing"
    static let modeIdentifier = "\(bundleIdentifier).Hans"

    static func currentIdentifier() -> String? {
        identifier(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    static func select(identifier requestedIdentifier: String) -> Bool {
        for source in allSources() where identifier(of: source) == requestedIdentifier {
            return TISSelectInputSource(source) == noErr
        }
        return false
    }

    static func register(bundleURL: URL) throws -> Int {
        let status = TISRegisterInputSource(bundleURL as CFURL)
        guard status == noErr else {
            throw RegistrationError.registrationFailed(status)
        }

        var enabledCount = 0
        var verifiedMode = false
        for source in allSources() {
            guard let sourceIdentifier = identifier(of: source),
                  sourceIdentifier == bundleIdentifier
                    || sourceIdentifier.hasPrefix("\(bundleIdentifier).") else {
                continue
            }
            guard sourceIdentifier == modeIdentifier else {
                // Enable only the input *mode*, never the parent method.
                // Enabling both makes macOS list 笔灵 twice in the input menu,
                // once for the method and once for the mode it contains.
                continue
            }
            guard isASCIICapable(source) == false else {
                throw RegistrationError.asciiCapable
            }
            verifiedMode = true
            if TISEnableInputSource(source) == noErr {
                enabledCount += 1
            }
        }
        guard verifiedMode else {
            throw RegistrationError.modeMissing
        }
        guard enabledCount > 0 else {
            throw RegistrationError.enableFailed
        }
        return enabledCount
    }

    private static func allSources() -> [TISInputSource] {
        guard let unmanaged = TISCreateInputSourceList(nil, true) else { return [] }
        return unmanaged.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func identifier(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func isASCIICapable(_ source: TISInputSource) -> Bool? {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceIsASCIICapable
        ) else {
            return nil
        }
        return (
            Unmanaged<AnyObject>
                .fromOpaque(pointer)
                .takeUnretainedValue() as? NSNumber
        )?.boolValue
    }
}

enum RegistrationError: LocalizedError {
    case registrationFailed(OSStatus)
    case asciiCapable
    case modeMissing
    case enableFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            "TISRegisterInputSource 失败：\(status)"
        case .asciiCapable:
            "笔灵被错误地注册成可输出 ASCII 的输入源，中/英键行为将不正确。"
        case .modeMissing:
            "macOS 未找到笔灵的简体中文输入模式。"
        case .enableFailed:
            "macOS 无法启用笔灵输入源。"
        }
    }
}
