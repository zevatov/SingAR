import Foundation
import CoreGraphics
import Combine

/// Human-readable menu/segment title for an enum shown in the menu or settings.
protocol MenuTitled {
    var title: String { get }
}

/// All user-tunable options. Values persist in UserDefaults and drive subsystems.
enum DictationMode: String, CaseIterable, MenuTitled {
    case hold
    case toggle
    var title: String { self == .hold ? "Hold-to-talk (удержание)" : "Toggle (нажал-сказал-нажал)" }
}

/// Which key triggers dictation.
enum HotkeyChoice: String, CaseIterable, MenuTitled {
    case rightOption
    case fnOrGlobe
    var title: String {
        switch self {
        case .rightOption: return "Правый ⌥ Option (рекоменд.)"
        case .fnOrGlobe:  return "Fn / Globe (требует отключить Apple-диктовку)"
        }
    }
    /// CGKeyCode for this trigger.
    var keyCode: CGKeyCode {
        switch self {
        case .rightOption: return 61  // Right Option
        case .fnOrGlobe:  return 63   // Fn / Globe
        }
    }
}

/// Cloud speech recognition backend.
/// Google Gemini 3.5 Transcribe is the flagship model with 2.6% WER and native code/punctuation awareness.
enum CloudModel: String, CaseIterable, MenuTitled {
    case localWhisperTurbo  = "local/whisper-turbo"              // Offline, 0 keys, Metal GPU
    case gemini35Transcribe = "google/gemini-3.5-transcribe"      // Google Free Tier, 2.6% WER
    case gpt4oTranscribe    = "openai/gpt-4o-transcribe"         // OpenRouter / OpenAI
    case groqWhisper        = "groq/whisper-large-v3"            // Ultra-speed ~300ms
    case localOnly          = "local/apple-speech"               // Offline on-device Apple Speech

    var title: String {
        switch self {
        case .localWhisperTurbo:  return "Локальный Whisper Turbo (Metal, 0 ключей, офлайн)"
        case .gemini35Transcribe: return "Google Gemini 3.5 Transcribe (Бесплатно / Быстро)"
        case .gpt4oTranscribe:    return "GPT-4o Transcribe (OpenRouter)"
        case .groqWhisper:        return "Groq Whisper Large v3 (Ультра-скорость ~300мс)"
        case .localOnly:          return "Только Apple Speech (без сети)"
        }
    }
}

enum ASRLanguage: String, CaseIterable, MenuTitled {
    case auto
    case ru
    case en

    var title: String {
        switch self {
        case .auto: return "Авто (RU / EN)"
        case .ru:   return "Русский (RU)"
        case .en:   return "English (EN)"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled         = "enabled"
        static let mode            = "mode"
        static let hotkey          = "hotkey"
        static let autoPunctuation = "autoPunctuation"
        static let voiceCommands   = "voiceCommands"
        static let livePartials    = "livePartials"
        static let pauseMedia      = "pauseMedia"
        static let cloudCleanup    = "cloudCleanup"
        static let cloudModel      = "cloudModel"
        static let language        = "language"
        static let launchAtLogin   = "launchAtLogin"
        static let stopOnFocusLoss = "stopOnFocusLoss"
    }

    // MARK: Bool toggles

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }
    @Published var autoPunctuation: Bool {
        didSet { defaults.set(autoPunctuation, forKey: Key.autoPunctuation) }
    }
    @Published var voiceCommands: Bool {
        didSet { defaults.set(voiceCommands, forKey: Key.voiceCommands) }
    }
    @Published var livePartials: Bool {
        didSet { defaults.set(livePartials, forKey: Key.livePartials) }
    }
    @Published var pauseMedia: Bool {
        didSet { defaults.set(pauseMedia, forKey: Key.pauseMedia) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    @Published var stopOnFocusLoss: Bool {
        didSet { defaults.set(stopOnFocusLoss, forKey: Key.stopOnFocusLoss) }
    }
    @Published var cloudCleanup: Bool {
        didSet { defaults.set(cloudCleanup, forKey: Key.cloudCleanup) }
    }

    // MARK: Enum options

    @Published var mode: DictationMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    @Published var hotkey: HotkeyChoice {
        didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey) }
    }
    @Published var cloudModel: CloudModel {
        didSet { defaults.set(cloudModel.rawValue, forKey: Key.cloudModel) }
    }
    @Published var language: ASRLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    private init() {
        defaults.register(defaults: [
            Key.enabled:         true,
            Key.mode:            DictationMode.toggle.rawValue,
            Key.hotkey:          HotkeyChoice.rightOption.rawValue,
            Key.autoPunctuation: true,
            Key.voiceCommands:   true,
            Key.livePartials:    false,
            Key.pauseMedia:      true,
            Key.cloudCleanup:    true,
            Key.cloudModel:      CloudModel.gemini35Transcribe.rawValue,
            Key.language:        ASRLanguage.auto.rawValue,
            Key.launchAtLogin:   false,
            Key.stopOnFocusLoss: true,
        ])

        self.enabled = defaults.bool(forKey: Key.enabled)
        self.autoPunctuation = defaults.bool(forKey: Key.autoPunctuation)
        self.voiceCommands = defaults.bool(forKey: Key.voiceCommands)
        self.livePartials = defaults.bool(forKey: Key.livePartials)
        self.pauseMedia = defaults.bool(forKey: Key.pauseMedia)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        self.stopOnFocusLoss = defaults.object(forKey: Key.stopOnFocusLoss) as? Bool ?? true
        self.cloudCleanup = defaults.object(forKey: Key.cloudCleanup) as? Bool ?? true

        self.mode = DictationMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .toggle
        self.hotkey = HotkeyChoice(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .rightOption
        self.cloudModel = CloudModel(rawValue: defaults.string(forKey: Key.cloudModel) ?? "") ?? .gemini35Transcribe
        self.language = ASRLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .auto
    }

}
