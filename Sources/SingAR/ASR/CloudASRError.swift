import Foundation

/// Gate 1.7: typed error model for cloud ASR paths (Gemini / OpenRouter / Groq).
/// Replaces ambiguous `nil` returns so callers can distinguish auth/quota/
/// network failures from a genuine "no speech" result without parsing strings.
/// Fallback contract is unchanged: any error still means "use live/local text".
enum CloudASRError: Error, Equatable {
    /// API key rejected (HTTP 401/403).
    case invalidKey(status: Int)
    /// Quota exceeded (HTTP 429).
    case rateLimited
    /// Server-side failure (HTTP 5xx or unexpected non-200).
    case serverError(status: Int)
    /// Transport-level failure (URLError from URLSession).
    case network(underlying: URLError)
    /// Request exceeded its timeoutInterval.
    case timeout
    /// Request was cancelled before completion (session abort / Esc).
    case cancelled
    /// Empty/unusable transcription (2xx but no text, or local encode miss).
    case emptySpeech
    /// Key not configured at all (SecretStore miss) — non-network.
    case missingKey

    /// Short user-facing message sized for the 180pt status capsule.
    var userMessage: String {
        switch self {
        case .invalidKey:          return "Неверный API-ключ"
        case .rateLimited:         return "Лимит запросов"
        case .serverError:         return "Ошибка сервера"
        case .network:             return "Нет сети"
        case .timeout:             return "Сервер не ответил"
        case .cancelled:           return "Отменено"
        case .emptySpeech:         return "Речь не распознана"
        case .missingKey:          return "Ключ не задан"
        }
    }

    /// Gate 1.7: only these surface a dedicated message in the UI today;
    /// everything else keeps the generic `.failed` state (behavior parity).
    var showsDedicatedMessage: Bool {
        switch self {
        case .invalidKey, .rateLimited, .network: return true
        default: return false
        }
    }
}

extension CloudASRError {
    /// Classify a URLSession transport error: timeout vs generic network.
    /// URLError.cancelled is preserved as its own case for session aborts.
    static func from(_ error: Error) -> CloudASRError {
        guard let urlError = error as? URLError else {
            return .network(underlying: URLError(.unknown))
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timeout
        default:
            return .network(underlying: urlError)
        }
    }

    /// Classify a non-200 HTTP status per the Gate 1.7 model.
    static func from(status: Int) -> CloudASRError {
        switch status {
        case 401, 403:
            return .invalidKey(status: status)
        case 429:
            return .rateLimited
        case 500...599:
            return .serverError(status: status)
        default:
            return .serverError(status: status)
        }
    }
}
