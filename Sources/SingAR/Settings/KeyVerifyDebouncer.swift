import Foundation

/// Этап 3: 500-мс дебаунс авто-верификации API-ключей в SettingsView.
///
/// Контракт: «смена ключа не должна спамить сеть — 1 запрос на паузу ввода».
/// Каждая новая `schedule` отменяет предыдущий Task; экшен выполняется только
/// если ввод «замер» на полный delay. Задержка инжектится (delayNanoseconds),
/// поэтому offline-тесты гоняют микросекундный delay без сети.
///
/// `@MainActor`: создаётся и вызывается только из SwiftUI-контекста
/// (`onChange`/кнопка); внутренний Task наследует main-контекст экшена.
@MainActor
final class KeyVerifyDebouncer {

    private var pendingTask: Task<Void, Never>?
    private let delayNanoseconds: UInt64

    /// Продакшен-константа: 500 мс паузы ввода перед сетевым запросом.
    nonisolated static let defaultDelayNanoseconds: UInt64 = 500_000_000

    init(delayNanoseconds: UInt64 = KeyVerifyDebouncer.defaultDelayNanoseconds) {
        self.delayNanoseconds = delayNanoseconds
    }

    /// Отменяет предыдущий запланированный вызов и планирует новый.
    /// Асимметрия против спама: N нажатий подряд ⇒ максимум 1 сетевой запрос.
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        pendingTask?.cancel()
        pendingTask = Task { [delayNanoseconds] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            // Отмена (новый ввод) инвалидирует запланированный запрос.
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// Немедленная отмена запланированного вызова (уход с экрана и т.п.).
    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// Pure-seam для тестов/ревью: должен ли «сырой» ввод ключа вообще
    /// запускать сеть. Пробельные/пустые значения сеть не трогают.
    /// Трим определяется единственным helper'ом `SecretStore.normalizedKey`.
    nonisolated static func shouldScheduleNetworkVerify(rawKey: String?) -> Bool {
        SecretStore.normalizedKey(rawKey) != nil
    }
}
