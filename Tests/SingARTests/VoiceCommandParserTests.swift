import XCTest
@testable import SingAR

/// Gate 0.6: распознанные команды и не-команды VoiceCommandParser.
final class VoiceCommandParserTests: XCTestCase {

    private let parser = VoiceCommandParser()

    // MARK: Распознанные команды

    func testPeriodCommand() {
        XCTAssertEqual(parser.process("точка"), ".")
    }

    func testEnglishPeriodCommand() {
        XCTAssertEqual(parser.process("period"), ".")
    }

    func testCommaCommand() {
        XCTAssertEqual(parser.process("запятая"), ",")
    }

    func testNewLineCommandWithinText() {
        XCTAssertEqual(parser.process("раз новая строка два"), "раз\n два")
    }

    func testEnglishNewLineCommandWithinText() {
        XCTAssertEqual(parser.process("first new line second"), "first\n second")
    }

    func testTripleWordSemicolon() {
        // 3-слова фраза должна съедаться целиком, не оставляя "с запятой".
        XCTAssertEqual(parser.process("точка с запятой"), ";")
    }

    func testIndentCommandWithinText() {
        XCTAssertEqual(parser.process("раз indent два"), "раз\t два")
    }

    func testTabCommandWithinText() {
        XCTAssertEqual(parser.process("раз таб два"), "раз\t два")
    }

    func testStandaloneNewLineCommandPreserved() {
        // Command-only вывод ("\n"/"\t") больше не обрезается trim'ом.
        XCTAssertEqual(parser.process("новая строка"), "\n")
        XCTAssertEqual(parser.process("new line"), "\n")
        XCTAssertEqual(parser.process("таб"), "\t")
    }

    // MARK: Stateful модификаторы (действуют на следующее слово, затем сброс)

    func testAllCapsAppliesToNextWordAndResets() {
        XCTAssertEqual(parser.process("all caps hello world"), "HELLO world")
    }

    func testAllCapsRussianAppliesToNextWord() {
        XCTAssertEqual(parser.process("раз все заглавные мир"), "раз МИР")
    }

    func testCamelCaseAppliesToNextWordAndResets() {
        XCTAssertEqual(parser.process("camelcase user-id bar"), "userId bar")
    }

    func testSnakeCaseAppliesToNextWordAndResets() {
        XCTAssertEqual(parser.process("снейккейс user-id bar"), "user_id bar")
    }

    func testNumeralConvertsNextWordToDigitsAndResets() {
        XCTAssertEqual(parser.process("numeral five apples"), "5 apples")
    }

    func testNumeralRussianConvertsNextWordToDigits() {
        XCTAssertEqual(parser.process("раз numeral три четыре"), "раз 3 четыре")
    }

    func testNumeralUnknownWordPassesThrough() {
        XCTAssertEqual(parser.process("number hello"), "hello")
    }

    // MARK: Не-команды

    func testPlainTextPassesThrough() {
        XCTAssertEqual(parser.process("привет мир"), "привет мир")
    }

    func testMixedCommandAndText() {
        XCTAssertEqual(parser.process("раз два три"), "раз два три")
    }

    func testEmptyString() {
        XCTAssertEqual(parser.process(""), "")
    }

    func testUnknownWordPreserved() {
        XCTAssertEqual(parser.process("суперфраза"), "суперфраза")
    }
}
