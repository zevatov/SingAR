import AppKit

/// Single-glyph status shown in the menu bar. Colour + symbol encode everything
/// the user needs at a glance: idle / listening / recognizing / cloud / done.
enum AppStatus {
    case idle
    case listening
    case recognizing
    case cloud
    case done

    var symbol: String {
        switch self {
        case .idle:         return "mic.fill"
        case .listening:    return "mic.fill"
        case .recognizing:  return "waveform"
        case .cloud:        return "arrow.triangle.2.circlepath"
        case .done:         return "checkmark.circle.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .idle:         return .secondaryLabelColor
        case .listening:    return .systemRed
        case .recognizing:  return .systemOrange
        case .cloud:        return .systemBlue
        case .done:         return .systemGreen
        }
    }

    var tooltip: String {
        switch self {
        case .idle:         return "SingAR — готов"
        case .listening:    return "SingAR — слушаю…"
        case .recognizing:  return "SingAR — распознаю…"
        case .cloud:        return "SingAR — облачный шаг…"
        case .done:         return "SingAR — готово"
        }
    }
}
