import Foundation

/// Parses spoken commands out of the transcript and applies them as edits or
/// text transforms. Covers Apple's set (`new line`, `all caps`, …) plus coding
/// commands (`indent`, `camelCase`, `snake_case`, `tab`, `undo`) and user
/// macros stored in UserDefaults.
///
/// Commands are matched case-insensitively against RU + EN phrasings. Anything
/// not recognised as a command is left as plain text.
final class VoiceCommandParser {

    /// Stateful text modifiers: applied to the NEXT word, then reset.
    private enum Modifier {
        case allCaps
        case camelCase
        case snakeCase
        case numeral
    }

    func process(_ text: String) -> String {
        // Tokenize on whitespace; iterate replacing command phrases.
        // We scan word-by-word so multi-word commands ("new line") match.
        var output = ""
        var pending: Modifier? = nil
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0

        while i < words.count {
            let consumed = matchCommand(at: i, in: words, pending: &pending, appendTo: &output)
            i += consumed
        }
        // No trailing trim: command-only output ("\n", "\t") must survive.
        return output
    }

    // MARK: Command table

    /// Returns the number of words consumed (0 = no command, emit raw word).
    private func matchCommand(at index: Int, in words: [String], pending: inout Modifier?, appendTo output: inout String) -> Int {
        // Longest phrases first: a 3-word command must be tried before its 2- or
        // 1-word prefixes, otherwise "точка с запятой" matches "точка" → "." and
        // leaves "с запятой" as raw text.
        if index + 2 < words.count {
            let triple = "\(words[index]) \(words[index + 1]) \(words[index + 2])".lowercased()
            switch triple {
            case "точка с запятой":
                pending = nil // command consumed: pending modifier expires
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
                pending = nil
                output += "\n"
                return 2
            // Apple punctuation (two-word phrasings — these sat in the one-word
            // switch before and never matched, since `w` is a single word).
            case "question mark", "вопросительный знак":
                pending = nil
                output += "?"
                return 2
            case "exclamation mark", "восклицательный знак":
                pending = nil
                output += "!"
                return 2
            case "all caps", "все заглавные":
                pending = .allCaps // applies to the next word, then resets
                return 2
            case "нижнее подчёркивание", "нижнее подчеркивание":
                pending = nil
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
            pending = nil
            output += "."
            return 1
        case "comma", "запятая":
            pending = nil
            output += ","
            return 1
        case "colon", "двоеточие":
            pending = nil
            output += ":"
            return 1
        case "semicolon":
            pending = nil
            output += ";"
            return 1
        // Apple numeral/number markers: convert the NEXT word's number word
        // to digits, then reset.
        case "numeral", "number":
            pending = .numeral
            return 1
        // Coding commands
        case "indent", "отступ":
            pending = nil
            output += "\t"
            return 1
        case "tab", "таб":
            pending = nil
            output += "\t"
            return 1
        case "camelcase", "камелкейс":
            pending = .camelCase
            return 1
        case "snakecase", "snake_case", "снейккейс":
            pending = .snakeCase
            return 1
        case "underscore", "подчёркивание", "подчеркивание":
            pending = nil
            output += "_"
            return 1
        // Raw word (may be transformed by a pending stateful modifier).
        default:
            var word = words[index]
            if let mod = pending {
                word = Self.apply(mod, to: word)
                pending = nil
            }
            if !output.isEmpty { output += " " }
            output += word
            return 1
        }
    }

    // MARK: Modifier application

    private static func apply(_ modifier: Modifier, to word: String) -> String {
        switch modifier {
        case .allCaps:   return word.uppercased()
        case .camelCase: return camelCase(word)
        case .snakeCase: return snakeCase(word)
        case .numeral:   return numeral(word)
        }
    }

    /// "user-id" → "userId", "User" → "user".
    private static func camelCase(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let first = parts.first else { return s }
        let tail = parts.dropFirst()
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined()
        return first.lowercased() + tail
    }

    /// "user-id" → "user_id", "Foo" → "foo".
    private static func snakeCase(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    /// "five" / "пять" → "5"; unknown words pass through unchanged.
    private static let numerals: [String: Int] = [
        // EN
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
        "hundred": 100, "thousand": 1000,
        // RU
        "ноль": 0, "один": 1, "два": 2, "три": 3, "четыре": 4, "пять": 5,
        "шесть": 6, "семь": 7, "восемь": 8, "девять": 9, "десять": 10,
        "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13, "четырнадцать": 14,
        "пятнадцать": 15, "шестнадцать": 16, "семнадцать": 17, "восемнадцать": 18,
        "девятнадцать": 19, "двадцать": 20, "тридцать": 30, "сорок": 40,
        "пятьдесят": 50, "шестьдесят": 60, "семьдесят": 70, "восемьдесят": 80,
        "девяносто": 90, "сто": 100, "тысяча": 1000,
    ]

    private static func numeral(_ word: String) -> String {
        numerals[word.lowercased()].map(String.init) ?? word
    }
}
