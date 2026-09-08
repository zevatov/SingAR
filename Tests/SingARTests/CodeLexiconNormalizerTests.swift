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
    }
}
