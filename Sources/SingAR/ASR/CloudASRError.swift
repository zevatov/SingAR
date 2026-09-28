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
    /// Whisper model file not found on disk.
    case missingModel

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
        case .missingModel:        return "Модель не загружена"
        }
    }

    /// Gate 1.7: only these surface a dedicated message in the UI today;
    /// everything else keeps the generic `.failed` state (behavior parity).
    var showsDedicatedMessage: Bool {
        switch self {
        case .invalidKey, .rateLimited, .network, .missingModel: return true
        default: return false
        }
    }

    /// Stable pipeline code. Status digits only — never a response body or URL.
    var logCode: String {
        switch self {
        case .invalidKey(let status): return "http_\(status)"
        case .rateLimited: return "http_429"
        case .serverError(let status): return "http_\(status)"
        case .network(let underlying): return "network_\(underlying.code.rawValue)"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .emptySpeech: return "empty_speech"
        case .missingKey: return "missing_key"
        case .missingModel: return "missing_model"
        }
    }

    /// Short reason with the same constraint as `logCode` (no body, no user text).
    var logReason: String {
        switch self {
        case .invalidKey: return "invalid_key"
        case .rateLimited: return "rate_limited"
        case .serverError: return "server_error"
        case .network(let underlying): return "url_error_\(underlying.code.rawValue)"
        case .timeout: return "request_timeout"
        case .cancelled: return "cancelled"
        case .emptySpeech: return "empty_result"
        case .missingKey: return "api_key_missing"
        case .missingModel: return "model_not_installed"
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
