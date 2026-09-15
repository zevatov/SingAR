import AppKit

/// Main entry point for SingAR.
/// A lightweight, privacy-first, Open-Source voice dictation assistant for macOS.
@main
enum SingARApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

