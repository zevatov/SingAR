import XCTest
@testable import SingAR

/// Gate 0.6: базовые трансформации и edge cases CodeLexiconNormalizer.
final class CodeLexiconNormalizerTests: XCTestCase {

    // MARK: Базовые трансформации

    func testNormalizeBasicNpmBuild() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize("нпм ран билд"), "npm run build")
    }

    func testNormalizeGitStatus() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize("гит статус"), "git status")
    }

    func testNormalizeGitStatusShort() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize("гит статус шорт"), "git status --short")
    }

    func testNormalizeCaseInsensitiveCyrillic() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize("НПМ ТЕСТ"), "npm test")
    }

    func testNormalizePhrasesPreserveOtherWords() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize("запушь гит пуш в репу"), "запушь git push в репу")
    }

    func testNormalizeTechTerm() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize("джейсон"), "JSON")
    }

    // MARK: Edge cases

    func testNormalizeEmptyString() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize(""), "")
    }

    func testNormalizeUnknownWordsUnchanged() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize("привет как дела"), "привет как дела")
    }

    func testCleanHallucinationsRemovesYouTubeJunk() {
        XCTAssertEqual(CodeLexiconNormalizer.cleanHallucinations("продолжу"), "")
        XCTAssertEqual(CodeLexiconNormalizer.cleanHallucinations("тишина"), "")
    }

    func testCleanHallucinationsKeepsNormalText() {
        XCTAssertEqual(CodeLexiconNormalizer.cleanHallucinations("обычный текст"), "обычный текст")
    }

    func testNormalizeOfHallucinationReturnsEmpty() {
        XCTAssertEqual(CodeLexiconNormalizer.normalize("спасибо за просмотр"), "")
        XCTAssertEqual(CodeLexiconNormalizer.normalize("Субтитры создавал DimaTorzok"), "")
        XCTAssertEqual(CodeLexiconNormalizer.normalize("..."), "")
        XCTAssertEqual(CodeLexiconNormalizer.normalize("... ..."), "")
    }

    func testTrailingHallucinationsStripped() {
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Сделай кнопку. Продолжение следует"),
            "Сделай кнопку."
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Сделай кнопку Продолжение следует"),
            "Сделай кнопку."
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Сделай кнопку.\nСубтитры создавал DimaTorzok"),
            "Сделай кнопку."
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Сделай кнопку Субтитры создавал DimaTorzok"),
            "Сделай кнопку."
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Создай кнопку и добавь обработчик клика. Субтитры создавал DimaTorzok"),
            "Создай кнопку и добавь обработчик клика."
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Привет мир. Спасибо за просмотр"),
            "Привет мир."
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Сделай коммит. Редактор субтитров А. Семкин, корректор А. Егорова"),
            "Сделай коммит."
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Привет мир... ..."),
            "Привет мир."
        )
    }

    func testFalsePositiveHallucinationsProtected() {
        // Legitimate user speech must NOT be stripped when preceded by conjunctions or verbs
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Напиши: продолжение следует"),
            "Напиши: продолжение следует"
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("сказал что продолжение следует"),
            "сказал что продолжение следует"
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Напиши историю о том, как субтитры создавал Дима Торжок"),
            "Напиши историю о том, как субтитры создавал Дима Торжок"
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Выведи в лог сообщение: продолжение следует"),
            "Выведи в лог сообщение: продолжение следует"
        )
        XCTAssertEqual(
            CodeLexiconNormalizer.normalize("Автором перевода была Вадимова"),
            "Автором перевода была Вадимова"
        )
    }
}
