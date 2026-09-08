import Foundation
import ServiceManagement

/// Bridges the launch-at-login UI flag to SMAppService (macOS 13+; package targets macOS 14).
/// `AppSettings.launchAtLogin` remains the UI source of truth; SM status is authoritative at sync time.
enum LaunchAtLoginManager {

    /// Reflects the actual SMAppService registration into the UI flag so the toggle never lies.
    static func syncFromSystem(settings: AppSettings) {
        let systemEnabled = (SMAppService.mainApp.status == .enabled)
        guard settings.launchAtLogin != systemEnabled else { return }
        AppLogger.shared.log("🔄 launchAtLogin: UI flag \(settings.launchAtLogin) -> SM status enabled=\(systemEnabled)")
        settings.launchAtLogin = systemEnabled
    }

    /// Applies a user toggle change: register/unregister via SMAppService; rolls the toggle back on failure.
    static func apply(_ enabled: Bool, settings: AppSettings) {
        let previous = settings.launchAtLogin
        settings.launchAtLogin = enabled // optimistic UI update; rolled back below on failure

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            AppLogger.shared.log("✅ launchAtLogin: SMAppService \(enabled ? "register" : "unregister") ok")
        } catch {
            let code = (error as NSError).code
            AppLogger.shared.log("❌ launchAtLogin: SMAppService \(enabled ? "register" : "unregister") failed (domain=\(type(of: error)), code=\(code)) — rolling back toggle to \(previous)")
            settings.launchAtLogin = previous
        }

        // Authoritative re-sync in case SM state diverged from the expectation.
        syncFromSystem(settings: settings)
    }
}
