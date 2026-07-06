import Foundation

/// Parses library filenames of the form:
///   "{Title} #tag1 #tag2 … (id).txt"
/// and derives a series key ("base title") so related parts group as one story.
struct ParsedFilename {
    var title: String
    var tags: [String]
    var storyID: String?
}

enum FilenameParser {

    // "^(title) (#tags…) ((id))$"  — applied to the stem with .txt removed
    private static let fnameRe = regex("^(.*?)\\s*((?:#\\w+\\s*)*)\\((\\d+)\\)$")

    // Trailing part/chapter markers stripped to find the series ("base") title.
    private static let stripPatterns: [NSRegularExpression] = [
        regex("\\s*\\[(?:file|part|pt|chapter|ch|disk|disc|vol(?:ume)?|book)\\s*\\.?\\s*\\d+(?:\\s*[-\u{2013}\u{2014}]\\s*\\d+)?\\]\\s*$"),
        // series keyword + number + any trailing subtitle -> drop
        // (groups "Title, Part 1 The Beginning", "Title, Day 5 - Afternoon")
        regex("\\s*[,\\-\u{2013}\u{2014}:]?\\s*\\b(?:part|parts|chapter|chapters|chap|book|vol(?:ume)?|act|day|night|episode|ep|scene|section|round)\\b\\.?\\s*\\d+[a-z]?\\b.*$"),
        regex("\\s*[,\\-\u{2013}\u{2014}]?\\s*\\b(?:parts?|chapters?|chap|ch|book|vol(?:ume)?|pt|file|episode|ep|sections?|sect|scene|day|disk|disc)\\b\\.?\\s*\\d+(?:\\s*(?:to|thru|through|and|[-\u{2013}\u{2014}&,])\\s*\\d+)*\\s*$"),
        regex("\\s*[-\u{2013}\u{2014}]\\s*\\d+(?:\\s*[-\u{2013}\u{2014}]\\s*\\d+)*\\s*$"),
        regex("\\s*,\\s*\\d+(?:\\s*[-\u{2013}\u{2014}]\\s*\\d+)*\\s*$"),
    ]
    private static let trailRe = regex("[\\s,\\-\u{2013}\u{2014}]+$")
    private static let tagRe = regex("#(\\w+)")

    // Roman / spelled part numbers after a series keyword -> digits
    // ("Part II" -> "Part 2", "Chapter Three" -> "Chapter 3"), so the strip
    // patterns above can remove them.
    private static let kwSeq = "part|parts|chapter|chapters|chap|book|vol|volume|act|day|night|episode|ep|scene|section|round|pt"
    private static let romanValues: [String: Int] = [
        "i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8,
        "ix": 9, "x": 10, "xi": 11, "xii": 12, "xiii": 13, "xiv": 14, "xv": 15,
        "xvi": 16, "xvii": 17, "xviii": 18, "xix": 19, "xx": 20, "xxi": 21,
        "xxii": 22, "xxiii": 23, "xxiv": 24, "xxv": 25]
    private static let spellValues: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]
    private static let romanRe = regex(
        "\\b(" + kwSeq + ")(\\s+)("
        + romanValues.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        + ")\\b")
    private static let spellRe = regex(
        "\\b(" + kwSeq + ")(\\s+)("
        + spellValues.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        + ")\\b")

    private static func normalizeTitle(_ title: String) -> String {
        var t = title
        for (re, table) in [(romanRe, romanValues), (spellRe, spellValues)] {
            while true {
                let ns = t as NSString
                guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
                      let n = table[ns.substring(with: m.range(at: 3)).lowercased()] else { break }
                t = ns.replacingCharacters(in: m.range,
                    with: ns.substring(with: m.range(at: 1))
                        + ns.substring(with: m.range(at: 2)) + String(n))
            }
        }
        return t
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; force-try is safe.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// `stem` is the filename without directory and without the trailing
    /// ".lzfse" compression suffix (but possibly with ".txt").
    static func parse(stem: String) -> ParsedFilename {
        var s = stem
        if s.lowercased().hasSuffix(".txt") { s = String(s.dropLast(4)) }
        let ns = s as NSString
        guard let m = fnameRe.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return ParsedFilename(title: s.trimmingCharacters(in: .whitespaces), tags: [], storyID: nil)
        }
        let title = normalizeTitle(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces))
        let tagBlock = ns.substring(with: m.range(at: 2))
        let id = ns.substring(with: m.range(at: 3))
        let tagNS = tagBlock as NSString
        let tags = tagRe.matches(in: tagBlock, range: NSRange(location: 0, length: tagNS.length))
            .map { tagNS.substring(with: $0.range(at: 1)).lowercased() }
        return ParsedFilename(title: title, tags: tags, storyID: id)
    }

    /// Series key: title with trailing part/chapter markers removed, lowercased.
    static func baseTitle(_ title: String) -> String {
        var t = title
        for _ in 0..<4 {
            let prev = t
            for pat in stripPatterns {
                t = pat.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
            }
            t = trailRe.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
            if t == prev { break }
        }
        let out = t.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? title.trimmingCharacters(in: .whitespaces) : out
    }
}
