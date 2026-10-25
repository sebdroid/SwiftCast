extension String {
    /// Removes control, format and line or paragraph separator scalars so device-supplied text
    /// can't move the cursor, inject terminal escapes or reorder the output. Spaces are kept.
    func sanitized() -> String {
        String(String.UnicodeScalarView(unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }))
    }
}
