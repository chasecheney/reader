import Foundation

/// One auto-tagging rule: if a story's text contains `phrase`
/// (case-insensitive, whole words), assign `tag`.
/// Several rules may point at the same tag ("army" → military,
/// "marine" → military, "air force" → military).
struct TagRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Word or phrase to look for in the story text.
    var phrase: String
    /// Tag to assign when the phrase is found (stored without the leading #).
    var tag: String
}

/// The user's phrase → tag rule set. Persisted as one JSON file in the
/// iCloud container root, so both the Mac and the iPad use the same library
/// (last writer wins, like the per-story metadata).
enum TagLibrary {

    static let filename = "TagLibrary.json"

    /// Canonical tag form: lowercase, no '#', no spaces.
    static func normalizeTag(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Drops empty/unusable rules and canonicalizes the rest.
    static func cleaned(_ rules: [TagRule]) -> [TagRule] {
        rules.compactMap { r in
            let phrase = r.phrase.trimmingCharacters(in: .whitespaces)
            let tag = normalizeTag(r.tag)
            guard !phrase.isEmpty, !tag.isEmpty else { return nil }
            return TagRule(id: r.id, phrase: phrase, tag: tag)
        }
    }

    // MARK: - Matching

    /// Compiled matcher for scanning story text. Build once per import run.
    struct Matcher {
        private let compiled: [(tag: String, regex: NSRegularExpression)]

        init(rules: [TagRule]) {
            compiled = TagLibrary.cleaned(rules).compactMap { r in
                let escaped = NSRegularExpression.escapedPattern(for: r.phrase)
                guard let re = try? NSRegularExpression(
                    pattern: "\\b" + escaped + "\\b",
                    options: [.caseInsensitive]) else { return nil }
                return (r.tag, re)
            }
        }

        var isEmpty: Bool { compiled.isEmpty }

        /// Tags whose phrase occurs in `text` (each tag checked until first hit).
        func tags(in text: String) -> Set<String> {
            var out: Set<String> = []
            let range = NSRange(location: 0, length: (text as NSString).length)
            for (tag, re) in compiled where !out.contains(tag) {
                if re.firstMatch(in: text, range: range) != nil {
                    out.insert(tag)
                }
            }
            return out
        }
    }
}
