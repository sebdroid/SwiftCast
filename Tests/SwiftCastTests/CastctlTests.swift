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

    @Test func stripsInvisibleFormatScalars() {
        #expect("Den\u{200E}\u{2066}TV\u{FEFF}".sanitized() == "DenTV")
    }

    @Test func keepsZeroWidthJoinerSequences() {
        let text = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"
        #expect(Array(text.sanitized().unicodeScalars) == Array(text.unicodeScalars))
    }

    @Test func keepsZeroWidthNonJoiner() {
        let text = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"
        #expect(Array(text.sanitized().unicodeScalars) == Array(text.unicodeScalars))
    }
}
