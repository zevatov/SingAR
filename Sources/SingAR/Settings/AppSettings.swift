import Foundation

/// All user-tunable options exposed through the menu bar. Values persist in
/// UserDefaults and drive every subsystem (audio, ASR, injection, media, cloud).
enum DictationMode: String, CaseIterable {
    case hold
    case toggle
    var title: String { self == .hold ? "Hold-to-talk" : "Toggle" }
}

enum MediaPauseMode: String, CaseIterable {
    case pause
    case duck
    var title: String { self == .pause ? "Полная пауза" : "Приглушить (duck)" }
}

enum CloudStep: String, CaseIterable {
    case off
    case reASR
    case llmPolish
    var title: String {
        switch self {
        case .off:      return "Off"
        case .reASR:    return "Re-ASR (GPT-4o-mini)"
        case .llmPolish: return "LLM-polish (Qwen3-Max)"
        }
    }
}

/// Which re-ASR model OpenRouter transcribes with. Ranked for vibe-coding.
enum ReASRModel: String, CaseIterable {
    case gpt4oMini = "openai/gpt-4o-mini-transcribe"   // best code/path recognition, ~1s, ~$0.00012
    case gpt4o     = "openai/gpt-4o-transcribe"        // premium, perfect slash-paths, 2× cost
    case turbo     = "openai/whisper-large-v3-turbo"   // budget, 0.46s, ~$0.00011
    case whisper3  = "openai/whisper-large-v3"
    case voxtral   = "mistralai/voxtral-mini-transcribe"
    var title: String {
        switch self {
        case .gpt4oMini: return "GPT-4o-mini-transcribe (recommended)"
        case .gpt4o:     return "GPT-4o-transcribe (premium)"
        case .turbo:     return "Whisper large-v3-turbo (fast/budget)"
        case .whisper3:  return "Whisper large-v3"
        case .voxtral:   return "Voxtral mini-transcribe"
        }
    }
}

enum ASRLanguage: String, CaseIterable {
    case auto, ru, en
    var title: String { self == .auto ? "Auto" : rawValue.uppercased() }
}

enum ASRModel: String, CaseIterable {
    case turbo
    case large
    var title: String { self == .turbo ? "large-v3-turbo" : "large-v3" }
}

final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Fired on any change so the menu / subsystems can refresh.
    var onChange: (() -> Void)?

    private enum Key {
        static let enabled        = "enabled"
        static let mode           = "mode"
        static let autoPunctuation = "autoPunctuation"
        static let voiceCommands  = "voiceCommands"
        static let livePartials   = "livePartials"
        static let pauseMedia     = "pauseMedia"
        static let mediaMode      = "mediaMode"
        static let cloudStep      = "cloudStep"
        static let reASRModel     = "reASRModel"
        static let language       = "language"
        static let model          = "model"
        static let launchAtLogin  = "launchAtLogin"
    }

    private init() {
        defaults.register(defaults: [
            Key.enabled:         true,
            Key.mode:            DictationMode.hold.rawValue,
            Key.autoPunctuation: true,
            Key.voiceCommands:   true,
            Key.livePartials:    true,
            Key.pauseMedia:      true,
            Key.mediaMode:       MediaPauseMode.pause.rawValue,
            Key.cloudStep:       CloudStep.off.rawValue,
            Key.reASRModel:      ReASRModel.gpt4oMini.rawValue,
            Key.language:        ASRLanguage.auto.rawValue,
            Key.model:           ASRModel.turbo.rawValue,
            Key.launchAtLogin:   false,
        ])
    }

    // MARK: Bool toggles

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled); fire() }
    }
    var autoPunctuation: Bool {
        get { defaults.bool(forKey: Key.autoPunctuation) }
        set { defaults.set(newValue, forKey: Key.autoPunctuation); fire() }
    }
    var voiceCommands: Bool {
        get { defaults.bool(forKey: Key.voiceCommands) }
        set { defaults.set(newValue, forKey: Key.voiceCommands); fire() }
    }
    var livePartials: Bool {
        get { defaults.bool(forKey: Key.livePartials) }
        set { defaults.set(newValue, forKey: Key.livePartials); fire() }
    }
    var pauseMedia: Bool {
        get { defaults.bool(forKey: Key.pauseMedia) }
        set { defaults.set(newValue, forKey: Key.pauseMedia); fire() }
    }
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin); fire() }
    }

    // MARK: Enum options

    var mode: DictationMode {
        get { DictationMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .hold }
        set { defaults.set(newValue.rawValue, forKey: Key.mode); fire() }
    }
    var mediaMode: MediaPauseMode {
        get { MediaPauseMode(rawValue: defaults.string(forKey: Key.mediaMode) ?? "") ?? .pause }
        set { defaults.set(newValue.rawValue, forKey: Key.mediaMode); fire() }
    }
    var cloudStep: CloudStep {
        get { CloudStep(rawValue: defaults.string(forKey: Key.cloudStep) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.cloudStep); fire() }
    }
    var language: ASRLanguage {
        get { ASRLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.language); fire() }
    }
    var model: ASRModel {
        get { ASRModel(rawValue: defaults.string(forKey: Key.model) ?? "") ?? .turbo }
        set { defaults.set(newValue.rawValue, forKey: Key.model); fire() }
    }
    var reASRModel: ReASRModel {
        get { ReASRModel(rawValue: defaults.string(forKey: Key.reASRModel) ?? "") ?? .gpt4oMini }
        set { defaults.set(newValue.rawValue, forKey: Key.reASRModel); fire() }
    }

    private func fire() { onChange?() }
}
