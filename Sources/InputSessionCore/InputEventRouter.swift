import Foundation

public struct InputModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = InputModifiers(rawValue: 1 << 0)
    public static let control = InputModifiers(rawValue: 1 << 1)
    public static let option = InputModifiers(rawValue: 1 << 2)
    public static let shift = InputModifiers(rawValue: 1 << 3)
}

public struct InputKeyEvent: Sendable {
    public let text: String
    public let keyCode: Int
    public let modifiers: InputModifiers

    public init(text: String, keyCode: Int, modifiers: InputModifiers = []) {
        self.text = text
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum InputAction: Equatable, Sendable {
    case append(String)
    case deleteBackward
    case cancelComposition
    case commitLiteral
    case commitSelected
    case commitSelectedAndPassThrough
    case commitLiteralAndPassThrough
    case selectCandidate(Int)
    case moveSelection(Int)
    case changePage(Int)
    case passThrough
    case consume
}

public enum InputEventRouter {
    public static func route(
        _ event: InputKeyEvent,
        hasComposition: Bool,
        candidateCount: Int,
        page: Int,
        pageSize: Int
    ) -> InputAction {
        if !event.modifiers.intersection([.command, .control, .option]).isEmpty {
            return hasComposition ? .commitLiteralAndPassThrough : .passThrough
        }

        switch event.keyCode {
        case 53:
            return hasComposition ? .cancelComposition : .passThrough
        case 51:
            return hasComposition ? .deleteBackward : .passThrough
        case 36, 76:
            return hasComposition ? .commitLiteral : .passThrough
        case 49:
            return hasComposition ? .commitSelected : .passThrough
        case 123:
            return hasComposition ? .moveSelection(-1) : .passThrough
        case 124:
            return hasComposition ? .moveSelection(1) : .passThrough
        case 125:
            return hasComposition ? .changePage(1) : .passThrough
        case 126:
            return hasComposition ? .changePage(-1) : .passThrough
        default:
            break
        }

        if event.text.count == 1,
           let digit = event.text.first?.wholeNumberValue,
           (1...9).contains(digit),
           hasComposition {
            let index = page * pageSize + digit - 1
            return index < candidateCount ? .selectCandidate(index) : .consume
        }

        let accepted = event.text.filter { $0.isASCII && ($0.isLetter || $0 == "'") }
        if !accepted.isEmpty, accepted.count == event.text.count {
            return .append(accepted)
        }

        return hasComposition ? .commitSelectedAndPassThrough : .passThrough
    }
}
