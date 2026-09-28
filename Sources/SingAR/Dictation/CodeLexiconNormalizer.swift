import Foundation

/// Fast offline code and terminal term normalizer for vibe-coders.
/// Converts phonetic Cyrillic transliterations into standard English programming terms.
enum CodeLexiconNormalizer {

    private static let replacements: [(pattern: String, template: String)] = [
        // CLI & Package Managers
        (#"(?i)\bнпм\s+ран\s+билд\b"#, "npm run build"),
        (#"(?i)\bнпм\s+инста[л]+[а-я]*\b"#, "npm install"),
        (#"(?i)\bнпм\s+старт\b"#, "npm start"),
        (#"(?i)\bнпм\s+тест\b"#, "npm test"),
        (#"(?i)\bнпм\s+дев\b"#, "npm run dev"),
        (#"(?i)\bнпм\b"#, "npm"),
        (#"(?i)\bнпх\b"#, "npx"),
        (#"(?i)\bярн\b"#, "yarn"),
        (#"(?i)\bкарго\b"#, "cargo"),
        (#"(?i)\bпип\b"#, "pip"),

        // Git commands & branches
        (#"(?i)\bгит\s+статус\s+шорт\b"#, "git status --short"),
        (#"(?i)\bгит\s+статус\b"#, "git status"),
        (#"(?i)\bгит\s+пуш\b"#, "git push"),
        (#"(?i)\bгит\s+пул\b"#, "git pull"),
        (#"(?i)\bгит\s+коммит\b"#, "git commit"),
        (#"(?i)\bгит\s+чек[ао]ут\b"#, "git checkout"),
        (#"(?i)\bгит\s+ветк[а-я]+\b"#, "git branch"),
        (#"(?i)\bориджин\s+мейн\b"#, "origin main"),
        (#"(?i)\bориджин\s+мастер\b"#, "origin master"),
        (#"(?i)\bгитхаб\b"#, "GitHub"),
        (#"(?i)\bгитлаб\b"#, "GitLab"),
        (#"(?i)\bгит\b"#, "git"),

        // Docker
        (#"(?i)\bдокер\s+компоуз\s+ап\b"#, "docker compose up -d"),
        (#"(?i)\bдокер\s+компоуз\b"#, "docker compose"),
        (#"(?i)\bдокер\s+билд\b"#, "docker build"),
        (#"(?i)\bдокер\s+ран\b"#, "docker run"),
        (#"(?i)\bдокер\b"#, "docker"),

        // Environment & Variables
        (#"(?i)\b(точка\s+енв|файл\s+енв|\.енв|дот\s+енв)\b"#, ".env"),
        (#"(?i)\bдатабейз\s+юрл\b"#, "DATABASE_URL"),
        (#"(?i)\bдатабейс\s+юрл\b"#, "DATABASE_URL"),

        // Formats & Protocols
        (#"(?i)\bджейсон\b"#, "JSON"),
        (#"(?i)\bапи\b"#, "API"),
        (#"(?i)\bюрл\b"#, "URL"),
        (#"(?i)\bхттп[с]?\b"#, "HTTPS"),
        (#"(?i)\bэстик[ей|эй]+\b"#, "SDK"),

        // Tech stack & UI components
        (#"(?i)\bпайтон[а-я]*\b"#, "Python"),
        (#"(?i)\bпитон[а-я]*\b"#, "Python"),
        (#"(?i)\bтайпскрипт[а-я]*\b"#, "TypeScript"),
        (#"(?i)\bджаваскрипт[а-я]*\b"#, "JavaScript"),
        (#"(?i)\bреакт[а-я]*\b"#, "React"),
        (#"(?i)\bнекст\s*джиэс\b"#, "Next.js"),
        (#"(?i)\bбэкенд[а-я]*\b"#, "backend"),
        (#"(?i)\bфронтенд[а-я]*\b"#, "frontend"),
        (#"(?i)\bсайдбар[а-я]*\b"#, "Sidebar"),
        (#"(?i)\bхэндл\s*клик\b"#, "handleClick")
    ]

    private static let standaloneHallucinationPatterns: [String] = [
        #"^(?i)\s*продолжу\.?\s*$"#,
        #"^(?i)\s*продолжение следует\.?\s*$"#,
        #"^(?i)\s*спасибо за просмотр\.?\s*$"#,
        #"^(?i)\s*субтитры\b[^\n]*$"#,
        #"^(?i)\s*редактор субтитров[^\n]*$"#,
        #"^(?i)\s*корректор[^\n]*$"#,
        #"^(?i)\s*копирайтер[^\n]*$"#,
        #"^(?i)\s*переведено[^\n]*$"#,
        #"^(?i)\s*перевод (и )?озвучк[а-я]*[^\n]*$"#,
        #"^(?i)\s*тишина\.?\s*$"#,
        #"^(?i)\s*dimatorzok[^\n]*$"#,
        #"^(?i)\s*дима торжок[^\n]*$"#,
        #"^(?i)\s*(елена |ольга )?вадимов[а-я]*[^\n]*$"#,
        #"^(?i)\s*семкин[^\n]*$"#,
        #"^(?i)\s*егоров[а-я]*[^\n]*$"#,
        #"^[\s.,…\-_–—]+$"# // only dots/punctuation
    ]

    /// Known end-credits / YouTube tail. The phrase itself, not a sentence boundary.
    private static let trailingHallucinationBody = #"(?:субтитры(?:\s+(?:создавал|сделал|подготовил|добавил))?.*|dimatorzok.*|дима\s+торжок.*|редактор\s+субтитров.*|корректор.*|(?:перевод[а-я]*\s*:?\s*)?(?:елена\s+|ольга\s+)?вадимов[а-я]*.*|семкин.*|егоров[а-я]*.*|продолжение\s+следует.*|спасибо\s+за\s+просмотр.*|перевод[а-я]*\s+и\s+озвучк[а-я]*.*)"#

    /// Legacy cut: credits only after `.` `!` `?` or a newline.
    private static let trailingHallucinationRegex = try! NSRegularExpression(
        pattern: "(?i)(?:[.!?\\n]+\\s*)\(trailingHallucinationBody)$",
        options: [.caseInsensitive]
    )

    /// Same credits at the end of a phrase that has no terminator before them.
    /// Requires a real prefix (`location > 0`), so a whole-line credit still
    /// goes through `isHallucinationLine` and is wiped entirely.
    private static let trailingHallucinationLooseRegex = try! NSRegularExpression(
        pattern: "(?i)(?:^|[\\s])\(trailingHallucinationBody)$",
        options: [.caseInsensitive]
    )

    /// Speech that mentions the credit phrase is not a tail: conjunction,
    /// verb, quote, or colon immediately before it.
    private static let falsePositivePrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:\b(?:как|что|про|о|об|написал|сказал|выведи|сообщение|фильм|сериал|был|была|были|зовут|и|или|а|но|чтобы|пусть)|[:"«'])\s*$"#,
        options: [.caseInsensitive]
    )

    private static let phantomDotsRegex = try! NSRegularExpression(
        pattern: #"(?:\s*[\.]{2,}|\s*…)+\s*$"#,
        options: []
    )

    /// Checks if a single standalone line is a known Whisper hallucination artifact.
    static func isHallucinationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        for pattern in standaloneHallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Strips full-string hallucinations, trailing subtitle noise, and phantom ellipses.
    static func cleanHallucinations(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 1. Check if the entire string matches a standalone hallucination pattern
        if isHallucinationLine(trimmed) {
            return ""
        }

        // 2. Normalize trailing phantom dots ("... ...", "…", "....") -> single dot
        let dotRange = NSRange(trimmed.startIndex..., in: trimmed)
        if phantomDotsRegex.firstMatch(in: trimmed, options: [], range: dotRange) != nil {
            let replaced = phantomDotsRegex.stringByReplacingMatches(in: trimmed, options: [], range: dotRange, withTemplate: ".")
            trimmed = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Trailing credits: after a terminator, or bare at the end of the
        // phrase. A conjunction / verb / quote / colon before the phrase keeps it.
        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = trailingHallucinationRegex.firstMatch(in: trimmed, options: [], range: fullRange)
            ?? trailingHallucinationLooseRegex.firstMatch(in: trimmed, options: [], range: fullRange) {
            let matchRange = match.range
            if matchRange.location > 0 {
                let nsTrimmed = trimmed as NSString
                let prefix = nsTrimmed.substring(to: matchRange.location)
                let prefixTrimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)

                let prefixNs = prefixTrimmed as NSString
                let checkRange = NSRange(location: 0, length: prefixNs.length)
                let isProtected = falsePositivePrefixRegex.firstMatch(in: prefixTrimmed, options: [], range: checkRange) != nil

                if !isProtected && !prefixTrimmed.isEmpty {
                    var cleanedPrefix = prefixTrimmed
                    if !cleanedPrefix.hasSuffix(".") && !cleanedPrefix.hasSuffix("!") && !cleanedPrefix.hasSuffix("?") && !cleanedPrefix.hasSuffix(";") {
                        cleanedPrefix += "."
                    }
                    trimmed = cleanedPrefix
                }
            }
        }

        return trimmed
    }

    static func normalize(_ input: String) -> String {
        guard !input.isEmpty else { return "" }
        let cleaned = cleanHallucinations(input)
        guard !cleaned.isEmpty else { return "" }

        var result = cleaned
        for (pattern, template) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
            }
        }
        return result
    }
}
