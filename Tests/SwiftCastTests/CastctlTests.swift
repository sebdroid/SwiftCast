import Testing
@testable import castctl

@Suite("castctl output sanitising")
struct CastctlTests {
    @Test func stripsEscapeSequences() {
        let text = "\u{1B}[2J\u{1B}]0;pwned\u{07}Living Room"
        #expect(text.sanitized() == "[2J]0;pwnedLiving Room")
    }

    @Test func stripsBidiOverride() {
        #expect("Kitchen\u{202E}vt".sanitized() == "Kitchenvt")
    }

    @Test func stripsLineAndParagraphSeparators() {
        #expect("Line\u{2028}Paragraph\u{2029}End".sanitized() == "LineParagraphEnd")
    }

    @Test func stripsNewlinesAndTabs() {
        #expect("a\nb\tc\r".sanitized() == "abc")
    }

    @Test func keepsPlainTextWithSpaces() {
        let text = "Living Room TV  (onn. 4K) é 日本"
        #expect(text.sanitized() == text)
    }
}
