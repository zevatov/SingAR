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

    private static let hallucinationPatterns: [String] = [
        #"^(?i)\s*продолжу\.?\s*$"#,
        #"^(?i)\s*продолжение следует\.?\s*$"#,
        #"^(?i)\s*спасибо за просмотр\.?\s*$"#,
        #"^(?i)\s*субтитры (сделал|подготовил)[^\n]*$"#,
        #"^(?i)\s*редактор субтитров[^\n]*$"#,
        #"^(?i)\s*копирайтер[^\n]*$"#,
        #"^(?i)\s*переведено[^\n]*$"#,
        #"^(?i)\s*тишина\.?\s*$"#
    ]

    static func cleanHallucinations(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in hallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    return ""
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
