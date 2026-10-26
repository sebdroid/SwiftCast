extension String {
    /// Removes control scalars, line or paragraph separators, the bidi control characters and
    /// the invisible operator scalars listed below, so device-supplied text can't inject terminal
    /// escapes or reorder the output. Other format scalars (soft hyphen, zero width space, tag
    /// characters used by subdivision flags) and spaces are kept.
    func sanitized() -> String {
        String(String.UnicodeScalarView(unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: false
            case .format:
                // U+200C and U+200D are kept so emoji sequences and joining scripts survive.
                switch scalar.value {
                case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: false
                default: true
                }
            default: true
            }
        }))
    }
}
