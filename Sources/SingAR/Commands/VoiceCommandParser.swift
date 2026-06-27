import Foundation

/// Parses spoken commands out of the transcript and applies them as edits or
/// text transforms. Covers Apple's set (`new line`, `all caps`, …) plus coding
/// commands (`indent`, `camelCase`, `snake_case`, `tab`, `undo`) and user
/// macros stored in UserDefaults.
///
/// TODO(M2): implement the command grammar + macro expansion.
final class VoiceCommandParser {

    func process(_ text: String) -> String {
        // TODO(M2): scan for commands, transform/emit accordingly.
        return text
    }
}
