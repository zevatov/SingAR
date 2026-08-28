import SwiftUI

/// Main entry point for SingAR.
/// A lightweight, privacy-first, Open-Source voice dictation assistant for macOS (Gemini 3.5).
@main
struct SingARApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
