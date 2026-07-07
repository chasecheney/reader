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

    // MARK: - Tag pack (per-market default rules, shipped as data)

    /// One rule as it appears in a pack file or a bundle manifest.
    struct PackRule: Codable, Hashable {
        var phrase: String
        var tag: String
    }

    /// The app's bundled default rule set. Each market SKU (Story Reader /
    /// Story Navigator) ships its own DefaultTagRules.json; the code is
    /// identical. Bump packVersion when the defaults change — new rules are
    /// merged additively on update, respecting user edits and deletions.
    struct TagPack: Codable {
        var packVersion: Int = 0
        var name: String = ""
        var rules: [PackRule] = []
    }

    static let pack: TagPack = {
        guard let url = Bundle.main.url(forResource: "DefaultTagRules",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(TagPack.self, from: data) else {
            return TagPack()
        }
        return p
    }()

    /// Stable identity of a rule for seed/merge bookkeeping.
    static func ruleKey(_ phrase: String, _ tag: String) -> String {
        phrase.lowercased() + "\u{2192}" + normalizeTag(tag)
    }

    /// Starter rule set from the bundled pack.
    /// Used when no saved Tag Library exists yet; the user can edit or clear
    /// these freely afterwards (a cleared library stays cleared).
    /// Matching is whole-word, so word variants are separate rules.
    static var defaultRules: [TagRule] {
        pack.rules.map { TagRule(phrase: $0.phrase, tag: $0.tag) }
    }

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

    /// Phrase -> regex pattern. A phrase may carry a "not followed by"
    /// exclusion after " !":  "navy !blue|blazer|suit|tie"  matches the
    /// whole word "navy" except when the next word is one of the listed
    /// ones (handles "navy blue" and hyphenated "navy-blue").
    static func pattern(for phrase: String) -> String {
        if let range = phrase.range(of: " !") {
            let base = String(phrase[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let words = phrase[range.upperBound...]
                .split(separator: "|")
                .map { NSRegularExpression.escapedPattern(
                    for: $0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            let escaped = NSRegularExpression.escapedPattern(for: base)
            if !words.isEmpty {
                return "\\b" + escaped + "\\b(?![\\s\\-]+(?:"
                    + words.joined(separator: "|") + ")\\b)"
            }
        }
        return "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
    }

    // MARK: - Matching

    /// Compiled matcher for scanning story text. Build once per import run.
    struct Matcher {
        private let compiled: [(tag: String, regex: NSRegularExpression)]

        init(rules: [TagRule]) {
            compiled = TagLibrary.cleaned(rules).compactMap { r in
                guard let re = try? NSRegularExpression(
                    pattern: TagLibrary.pattern(for: r.phrase),
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
