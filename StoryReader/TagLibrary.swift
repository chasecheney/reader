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

    /// Starter rule set, matching the vocabulary the corpus was tagged with.
    /// Used when no saved Tag Library exists yet; the user can edit or clear
    /// these freely afterwards (a cleared library stays cleared).
    /// Matching is whole-word, so word variants are separate rules.
    static let defaultRules: [TagRule] = [
        // bondage
        TagRule(phrase: "bondage", tag: "bond"),
        TagRule(phrase: "S&M", tag: "bond"),
        // rape
        TagRule(phrase: "rape", tag: "rape"),
        TagRule(phrase: "rapes", tag: "rape"),
        TagRule(phrase: "raped", tag: "rape"),
        // gangbang
        TagRule(phrase: "gangbang", tag: "gangbang"),
        TagRule(phrase: "gang bang", tag: "gangbang"),
        // gloryhole
        TagRule(phrase: "gloryhole", tag: "gloryhole"),
        TagRule(phrase: "glory hole", tag: "gloryhole"),
        // humiliation
        TagRule(phrase: "humiliation", tag: "humil"),
        TagRule(phrase: "humiliate", tag: "humil"),
        TagRule(phrase: "humiliated", tag: "humil"),
        TagRule(phrase: "humiliates", tag: "humil"),
        // incest
        TagRule(phrase: "incest", tag: "incest"),
        // orgy
        TagRule(phrase: "orgy", tag: "orgy"),
        // prison
        TagRule(phrase: "prison", tag: "prison"),
        TagRule(phrase: "jail", tag: "prison"),
        TagRule(phrase: "cellmate", tag: "prison"),
        TagRule(phrase: "cell mate", tag: "prison"),
        TagRule(phrase: "sentenced", tag: "prison"),
        TagRule(phrase: "slammer", tag: "prison"),
        // slave
        TagRule(phrase: "slave", tag: "slave"),
        TagRule(phrase: "slaves", tag: "slave"),
        TagRule(phrase: "enslave", tag: "slave"),
        TagRule(phrase: "enslaved", tag: "slave"),
        TagRule(phrase: "slavery", tag: "slave"),
        TagRule(phrase: "enslavement", tag: "slave"),
        TagRule(phrase: "enslaver", tag: "slave"),
        // military — navy counts only when it isn't the color/clothing
        TagRule(phrase: "army", tag: "military"),
        TagRule(phrase: "marine", tag: "military"),
        TagRule(phrase: "marines", tag: "military"),
        TagRule(phrase: "air force", tag: "military"),
        TagRule(phrase: "airforce", tag: "military"),
        TagRule(phrase: "coast guard", tag: "military"),
        TagRule(phrase: "navy !blue|blazer|suit|tie", tag: "military"),
        // uniform
        TagRule(phrase: "uniform", tag: "uniform"),
        // police
        TagRule(phrase: "police", tag: "police"),
        TagRule(phrase: "sheriff", tag: "police"),
        // war — strong contextual phrases only; the bare word "war"
        // matches too many figurative uses to be a default
        TagRule(phrase: "world war", tag: "war"),
        TagRule(phrase: "wartime", tag: "war"),
        TagRule(phrase: "battlefield", tag: "war"),
        TagRule(phrase: "war zone", tag: "war"),
    ]

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
