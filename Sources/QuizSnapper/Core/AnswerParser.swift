import Foundation

enum AnswerParser {
    private static let letterSet = Set("ABCDEFGHIJ")
    private static let trimSet = CharacterSet(charactersIn: " \t*_#>`")
    /// Words that may join letters: "A and C", "A și C", "B or D".
    private static let joiners: Set<String> = ["and", "or", "și", "si", "sau", "&", "+", "y", "et", "und"]

    /// Extracts the answer letter(s) ("B", "A,C", "1:B 2:D") from a model reply, if any.
    static func letters(from answer: String) -> String? {
        let lines = answer
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        if first.lowercased().hasPrefix("no quiz") { return nil }

        // Multi-question format: "1: B", "2) A, C", "Q3 - D"
        let numbered = lines.compactMap { line -> String? in
            guard let match = line.range(of: #"^(?:Q|q)?(\d{1,2})\s*[:).\-–—]\s*"#, options: .regularExpression) else { return nil }
            let number = line[match].filter(\.isNumber)
            guard let l = leadingLetters(String(line[match.upperBound...])) else { return nil }
            return "\(number):\(l)"
        }
        if numbered.count > 1 { return numbered.joined(separator: " ") }

        if let l = leadingLetters(first) { return l }

        // "Answer: B", "The correct answer is C", "Răspuns corect: D"
        let pattern = #"(?i)(?:correct answer(?: is)?|answer(?: is)?|răspuns(?:ul)?(?: corect)?(?: este)?|raspuns(?:ul)?(?: corect)?(?: este)?|correct)\s*[:\-–—]?\s*"#
        for line in lines.prefix(4) {
            if let range = line.range(of: pattern, options: .regularExpression),
               let l = leadingLetters(String(line[range.upperBound...]), lenient: true) {
                return l
            }
        }
        return nil
    }

    /// Letters at the very start of a line, accepted only when they clearly *are* an answer:
    /// "B", "B — because…", "(D)", "A, C", "A and C.", "**C**: …". Rejects prose like "A function is…".
    static func leadingLetters(_ text: String, lenient: Bool = false) -> String? {
        var rest = Substring(text.trimmingCharacters(in: trimSet))
        var found: [Character] = []
        var terminated = false

        func skipSpaces() { while let c = rest.first, c == " " || c == "\t" { rest.removeFirst() } }

        while true {
            skipSpaces()
            // Optional wrapping: "(B)", "[B]", "B)", "B."
            var wrapped = false
            if let c = rest.first, c == "(" || c == "[" { rest.removeFirst(); wrapped = true }
            guard let c = rest.first, letterSet.contains(c) else {
                if wrapped { return nil }
                break
            }
            let next = rest.dropFirst().first
            if let next, next.isLetter || next.isNumber { break } // start of a word ("Because", "A1")
            found.append(c)
            rest.removeFirst()
            if wrapped { terminated = true }
            if let n = rest.first, n == ")" || n == "]" { rest.removeFirst(); terminated = true }
            if let n = rest.first, n == ".", rest.dropFirst().first?.isLetter != true { rest.removeFirst(); terminated = true }
            rest = rest.drop { $0 == "*" || $0 == "_" || $0 == "`" }
            skipSpaces()
            // Separators between letters. Having one at all ends the answer token, so a
            // trailing justification is fine ("B; because it floats", "A, C — both prime").
            if let n = rest.first, n == "," || n == ";" || n == "/" || n == "&" || n == "+" {
                rest.removeFirst()
                terminated = true
                continue
            }
            // Joining words
            let word = rest.prefix { $0.isLetter || $0 == "&" }.lowercased()
            if !word.isEmpty, joiners.contains(word) {
                let after = rest.dropFirst(word.count)
                let afterTrim = after.drop { $0 == " " }
                if let l = afterTrim.first, letterSet.contains(l), !(afterTrim.dropFirst().first?.isLetter ?? false) {
                    rest = after
                    continue
                }
            }
            break
        }
        guard !found.isEmpty else { return nil }

        // What follows must look like the end of an answer token, not the rest of a sentence.
        skipSpaces()
        if let n = rest.first {
            let ok: Set<Character> = ["—", "–", "-", ":", ".", ")", "|", "=", "→", "(", "\u{2014}", "!"]
            if !ok.contains(n) {
                // A lowercase word straight after a single letter ("A function") is prose.
                if found.count == 1 && !terminated && !lenient { return nil }
            }
        }
        return found.map(String.init).joined(separator: ",")
    }

    static func firstLine(of answer: String, limit: Int = 22) -> String {
        let line = answer.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: trimSet) }
            .first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// The reply without its first line (when the first line is just the letters).
    static func explanation(of answer: String) -> String {
        var lines = answer.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first, let l = leadingLetters(first),
           first.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_#>`.()[]")).count <= l.count + 6 {
            lines.removeFirst()
        } else if let first = lines.first, fillInValues(from: first) != nil {
            // The first line was the list of values — the UI shows it on its own.
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Answer shape (letters to click vs. values to type)

/// What kind of answer the model gave, so the UI can react differently:
/// letters are short enough to flash in the menu bar, typed values go to the clipboard.
enum AnswerShape: Equatable {
    /// Multiple choice: "B", "A,C", or "1:B 2:A,D" for several questions.
    case letters(String)
    /// Fill‑in‑the‑blank: one value per box/gap, in the order they appear.
    case fillIn([String])
    case none

    /// Fill‑in values as one pasteable string ("chmod 755; /etc/passwd; 3").
    var clipboardText: String? {
        guard case .fillIn(let values) = self, !values.isEmpty else { return nil }
        return values.joined(separator: "; ")
    }

    var isFillIn: Bool { clipboardText != nil }
}

extension AnswerParser {
    /// Classifies a reply. The explicit `FILL:` marker (asked for in the quiz prompt) wins,
    /// then answer letters, then a looser guess at a list of typed values.
    static func shape(of answer: String) -> AnswerShape {
        if let values = markedFillIn(in: answer) { return .fillIn(values) }
        if let letters = letters(from: answer) { return .letters(letters) }
        if let values = fillInValues(from: answer) { return .fillIn(values) }
        return .none
    }

    /// Values for the boxes of a fill‑in question, or nil if the reply doesn't look like one.
    static func fillInValues(from answer: String) -> [String]? {
        if let marked = markedFillIn(in: answer) { return marked }
        let lines = answerLines(answer)
        guard let first = lines.first, !first.lowercased().hasPrefix("no quiz") else { return nil }

        // Semicolon‑separated values on the first line, without the marker.
        if first.contains(";"), first.count <= 300 {
            let parts = first.split(separator: ";").map { cleanValue($0) }.filter { !$0.isEmpty }
            if parts.count >= 2, parts.allSatisfy({ looksLikeValue($0, strict: true) }),
               // "B; because it floats" is a letter answer with a justification, not two boxes.
               !(parts.count == 2 && isSingleLetter(parts[0])) {
                return parts
            }
        }

        // A numbered list of values: "1. chmod 755", "2) /etc/passwd" (letter answers are
        // caught earlier by `letters(from:)`, so what lands here is typed text).
        var values: [String] = []
        var expected = 1
        for line in lines {
            guard let marker = line.range(of: #"^(?:Q|q)?\d{1,2}\s*[:).\-–—]\s*"#, options: .regularExpression) else { continue }
            guard Int(line[marker].filter(\.isNumber)) == expected else { break }
            let value = cleanValue(line[marker.upperBound...])
            guard looksLikeValue(value, strict: true) else { break }
            values.append(value)
            expected += 1
        }
        return values.count >= 2 ? values : nil
    }

    /// `FILL: a; b; c` — the format the quiz prompt asks for.
    private static func markedFillIn(in answer: String) -> [String]? {
        for line in answerLines(answer).prefix(3) {
            guard let marker = line.range(of: #"(?i)^(?:fill(?:[ \-]?in)?|complete|text)\s*[:\-–—]\s*"#,
                                          options: .regularExpression) else { continue }
            let parts = line[marker.upperBound...].split(separator: ";").map { cleanValue($0) }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts }
        }
        return nil
    }

    private static func answerLines(_ answer: String) -> [String] {
        answer.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
    }

    /// Short enough to be something you type into a box, rather than a sentence. Without the
    /// explicit `FILL:` marker the bar is higher, so a semicolon in prose isn't mistaken for
    /// a list of answers ("…in the chloroplasts; respiration in the mitochondria").
    private static func looksLikeValue(_ value: String, strict: Bool = false) -> Bool {
        guard !value.isEmpty else { return false }
        let words = value.split(separator: " ").count
        return strict ? (value.count <= 24 && words <= 3) : (value.count <= 48 && words <= 5)
    }

    private static func isSingleLetter(_ value: String) -> Bool {
        value.count == 1 && value.uppercased().first.map(letterSet.contains) == true
    }

    private static func cleanValue(_ raw: some StringProtocol) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "*_`\"'“”‘’ \t"))
        if v.count > 1, v.hasSuffix(".") { v.removeLast() }
        return v.trimmingCharacters(in: .whitespaces)
    }
}
