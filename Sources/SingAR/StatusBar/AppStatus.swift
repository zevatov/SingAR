import AppKit

/// Single-glyph status shown in the menu bar and overlay capsule.
enum AppStatus: Equatable {
    case idle
    case listening
    case recognizing
    case inserting
    case failed

    var symbol: String {
        switch self {
        case .idle:         return "mic.fill"
        case .listening:    return "mic.fill"
        case .recognizing:  return "sparkles"
        case .inserting:    return "doc.on.doc.fill"
        case .failed:       return "xmark.circle.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .idle:         return .labelColor
        case .listening:    return .systemCyan
        case .recognizing:  return .systemPurple
        case .inserting:    return .systemGreen
        case .failed:       return .systemRed
        }
    }

    var tooltip: String {
        switch self {
        case .idle:         return "SingAR — готов"
        case .listening:    return "SingAR — запись"
        case .recognizing:  return "SingAR — обработка"
        case .inserting:    return "SingAR — вставка"
        case .failed:       return "SingAR — ошибка"
        }
    }

    /// Short label shown as a status row in the dropdown menu.
    var menuLabel: String {
        switch self {
        case .idle:         return "Готов к диктовке"
        case .listening:    return "Запись"
        case .recognizing:  return "Обработка"
        case .inserting:    return "Вставка"
        case .failed:       return "Ошибка"
        }
    }
}
