extension String {
    /// The string without control, format and line or paragraph separator scalars, so text a device
    /// sends cannot smuggle terminal escapes or bidirectional overrides into log lines.
    var displaySanitized: String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        })
        return String(scalars)
    }
}
