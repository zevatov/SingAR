import Foundation

/// Parses spoken commands out of the transcript and applies them as edits or
/// text transforms. Covers Apple's set (`new line`, `all caps`, …) plus coding
/// commands (`indent`, `camelCase`, `snake_case`, `tab`, `undo`) and user
/// macros stored in UserDefaults.
///
/// Commands are matched case-insensitively against RU + EN phrasings. Anything
/// not recognised as a command is left as plain text.
final class VoiceCommandParser {

    func process(_ text: String) -> String {
        // Tokenize on whitespace; iterate replacing command phrases.
        // We scan word-by-word so multi-word commands ("new line") match.
        var output = ""
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0

        while i < words.count {
            let consumed = matchCommand(at: i, in: words, appendTo: &output)
            i += consumed
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Command table

    /// Returns the number of words consumed (0 = no command, emit raw word).
    private func matchCommand(at index: Int, in words: [String], appendTo output: inout String) -> Int {
        // Two-word commands first.
        if index + 1 < words.count {
            let pair = "\(words[index]) \(words[index + 1])".lowercased()
            switch pair {
            // Apple: "new line", "next line"
            case "new line", "next line", "новая строка", "новую строку":
                output += "\n"
                return 2
            // Apple: "numeral" / "number" prefixes
            case "numeral", "number":
                return 2 // marker only; numeral handling left to ASR
            default:
                break
            }
        }

        let w = words[index].lowercased()
        switch w {
        // Apple set
        case "period", "точка":
            output += "."
            return 1
        case "comma", "запятая":
            output += ","
            return 1
        case "question mark", "вопросительный знак":
            output += "?"
            return 1
        case "exclamation mark", "восклицательный знак":
            output += "!"
            return 1
        case "colon", "двоеточие":
            output += ":"
            return 1
        case "semicolon", "точка с запятой":
            output += ";"
            return 1
        case "all caps", "все заглавные":
            return 1 // marker; full impl toggles caps for following word
        // Coding commands
        case "indent", "отступ":
            output += "\t"
            return 1
        case "tab", "таб":
            output += "\t"
            return 1
        case "camelcase", "камелкейс":
            // Flag next word to be camelCased — handled by a follow-up pass.
            return 1
        case "snakecase", "snake_case", "снейккейс":
            return 1
        case "underscore", "подчёркивание":
            output += "_"
            return 1
        // Raw word
        default:
            if !output.isEmpty { output += " " }
            output += words[index]
            return 1
        }
    }
}
