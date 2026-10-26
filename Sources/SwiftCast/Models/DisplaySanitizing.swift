extension String {
    /// The string without control, line separator and paragraph separator scalars, bidirectional
    /// marks, embeddings, overrides and isolates, the word joiner and invisible operators, and the
    /// byte order mark, so text a device sends cannot smuggle terminal escapes or bidirectional
    /// overrides into log lines. Other format scalars pass, such as U+200B, U+00AD and the tag
    /// characters that subdivision flags are built from.
    var displaySanitized: String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: unicodeScalars.filter { scalar in
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
        })
        return String(scalars)
    }
}
