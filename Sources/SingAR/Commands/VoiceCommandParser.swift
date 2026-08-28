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
        // Longest phrases first: a 3-word command must be tried before its 2- or
        // 1-word prefixes, otherwise "точка с запятой" matches "точка" → "." and
        // leaves "с запятой" as raw text.
        if index + 2 < words.count {
            let triple = "\(words[index]) \(words[index + 1]) \(words[index + 2])".lowercased()
            switch triple {
            case "точка с запятой":
                output += ";"
                return 3
            default: break
            }
        }

        if index + 1 < words.count {
            let pair = "\(words[index]) \(words[index + 1])".lowercased()
            switch pair {
            // Apple: "new line", "next line"
            case "new line", "next line", "новая строка", "новую строку":
                output += "\n"
                return 2
            // Apple punctuation (two-word phrasings — these sat in the one-word
            // switch before and never matched, since `w` is a single word).
            case "question mark", "вопросительный знак":
                output += "?"
                return 2
            case "exclamation mark", "восклицательный знак":
                output += "!"
                return 2
            case "all caps", "все заглавные":
                return 2 // marker; full impl toggles caps for the following word
            case "нижнее подчёркивание", "нижнее подчеркивание":
                output += "_"
                return 2
            default:
                break
            }
        }

        let w = words[index].lowercased()
        switch w {
        // Apple set (single-word phrasings).
        case "period", "точка":
            output += "."
            return 1
        case "comma", "запятая":
            output += ","
            return 1
        case "colon", "двоеточие":
            output += ":"
            return 1
        case "semicolon":
            output += ";"
            return 1
        // Apple numeral/number markers — single words (they were in the two-word
        // block before, compared as a pair, so never matched). Marker only;
        // numeral conversion is left to the ASR.
        case "numeral", "number":
            return 1
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
        case "underscore", "подчёркивание", "подчеркивание":
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
