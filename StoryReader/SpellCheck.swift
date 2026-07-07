import Foundation
import SwiftUI

/// Spell checker backed by the bundled `dictionary.txt` — a word list derived
/// from the story corpus itself (document-frequency filtered, typo-guarded),
/// so it ships with the app free of any license restrictions and already
/// knows the library's slang, names, and contractions. Unknown words the
/// user accepts go into a synced personal dictionary.
/// One unknown word's library-wide footprint (Learn Words / import review).
struct WordStat: Identifiable, Hashable, Sendable {
    var id: String { word }
    let word: String
    let files: Int        // distinct stories containing it
    let occurrences: Int
}

final class SpellCheck: @unchecked Sendable {

    static let shared = SpellCheck()

    private var words: Set<String> = []
    /// word -> rank. The bundled list is ordered by how common each word is
    /// in the corpus (line 0 = most common), which drives suggestion ranking.
    private var rank: [String: Int] = [:]
    private var loaded = false
    private let lock = NSLock()

    /// Loads the bundled dictionary once (≈30k words, instant).
    func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "dictionary",
                                        withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        var r: [String: Int] = [:]
        for (i, line) in text.split(separator: "\n").enumerated() {
            r[String(line)] = i
        }
        rank = r
        words = Set(r.keys)
    }

    private static let tokenRe = try! NSRegularExpression(
        pattern: "[a-z]+(?:'[a-z]+)?")

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    func isKnown(_ token: String, user: Set<String>) -> Bool {
        if token.count <= 1 { return true }
        if words.contains(token) || user.contains(token) { return true }
        // possessives: brian's / boys' -> brian / boys
        if token.hasSuffix("'s"), words.contains(String(token.dropLast(2)))
            || user.contains(String(token.dropLast(2))) { return true }
        if token.hasSuffix("'"), words.contains(String(token.dropLast()))
            || user.contains(String(token.dropLast())) { return true }
        return false
    }

    struct Finding: Identifiable, Hashable {
        var id: String { word }
        let word: String
        let count: Int
        let suggestions: [String]
    }

    /// All unknown words in `text` with counts and up to 3 suggestions,
    /// most frequent first.
    func unknownWords(in text: String, user: Set<String>) -> [Finding] {
        loadIfNeeded()
        let norm = Self.normalize(text)
        let ns = norm as NSString
        var counts: [String: Int] = [:]
        for m in Self.tokenRe.matches(in: norm,
                                      range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            if !isKnown(tok, user: user) {
                counts[tok, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { Finding(word: $0.key, count: $0.value,
                           suggestions: suggestions(for: $0.key, user: user)) }
    }

    /// Lightweight bulk scan: unknown word -> occurrence count for one text.
    /// (No suggestions — far too slow across a whole library.)
    func unknownCounts(in text: String, user: Set<String>) -> [String: Int] {
        loadIfNeeded()
        let norm = Self.normalize(text)
        let ns = norm as NSString
        var counts: [String: Int] = [:]
        for m in Self.tokenRe.matches(in: norm,
                                      range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            if !isKnown(tok, user: user) {
                counts[tok, default: 0] += 1
            }
        }
        return counts
    }

    /// Known words within edit distance 1 (same-first-letter ones first).
    func suggestions(for word: String, user: Set<String>, limit: Int = 3) -> [String] {
        loadIfNeeded()
        let alpha = "abcdefghijklmnopqrstuvwxyz'"
        var variants: Set<String> = []
        let chars = Array(word)
        for i in 0..<chars.count {
            variants.insert(String(chars[0..<i] + chars[(i+1)...]))          // delete
            if i < chars.count - 1 {                                          // transpose
                var t = chars; t.swapAt(i, i + 1); variants.insert(String(t))
            }
            for c in alpha {                                                  // replace
                var t = chars; t[i] = c; variants.insert(String(t))
            }
        }
        for i in 0...chars.count {                                            // insert
            for c in alpha {
                var t = chars; t.insert(c, at: i); variants.insert(String(t))
            }
        }
        variants.remove(word)
        let known = variants.filter { words.contains($0) || user.contains($0) }
        // Most common corpus word first — "teh" suggests "the", not "tea".
        let ranked = known.sorted {
            let ra = rank[$0] ?? Int.max, rb = rank[$1] ?? Int.max
            if ra != rb { return ra < rb }
            return $0 < $1
        }
        return Array(ranked.prefix(limit))
    }

    /// Replace every whole-word occurrence (case-insensitive), preserving a
    /// leading capital per occurrence ("Recieve" -> "Receive").
    static func replaceAll(_ word: String, with replacement: String,
                           in text: String) -> String {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text,
                            range: NSRange(location: 0, length: ns.length)).reversed() {
            let original = ns.substring(with: m.range)
            var rep = replacement
            if let first = original.first, first.isUppercase {
                rep = replacement.prefix(1).uppercased() + replacement.dropFirst()
            }
            if let range = Range(m.range, in: out) {
                out.replaceSubrange(range, with: rep)
            }
        }
        return out
    }
}

/// Spelling panel for edit mode: unknown words with counts, one-tap
/// replace-all suggestions, and add-to-dictionary.
struct SpellingView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String

    @State private var findings: [SpellCheck.Finding] = []
    @State private var scanning = true

    var body: some View {
        NavigationStack {
            List {
                if scanning {
                    HStack { ProgressView(); Text("Checking…") }
                } else if findings.isEmpty {
                    ContentUnavailableView("No Unknown Words",
                                           systemImage: "checkmark.seal",
                                           description: Text("Everything matches the dictionary."))
                } else {
                    Section {
                        ForEach(findings) { f in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(f.word).font(.headline)
                                    Text("×\(f.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Add to Dictionary") {
                                        vm.addToUserDictionary(f.word)
                                        findings.removeAll { $0.word == f.word }
                                    }
                                    .font(.caption)
                                }
                                if !f.suggestions.isEmpty {
                                    HStack(spacing: 8) {
                                        Text("Replace all with:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ForEach(f.suggestions, id: \.self) { s in
                                            Button(s) {
                                                text = SpellCheck.replaceAll(
                                                    f.word, with: s, in: text)
                                                findings.removeAll { $0.word == f.word }
                                            }
                                            .buttonStyle(.bordered)
                                            .font(.caption)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } footer: {
                        Text("Checked against the bundled corpus dictionary plus your personal dictionary (synced between devices). “Add to Dictionary” stops a word from ever being flagged again.")
                    }
                }
            }
            .navigationTitle(scanning ? "Spelling"
                             : "Spelling — \(findings.count) words")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await scan() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
    }

    private func scan() async {
        scanning = true
        let snapshot = text
        let user = vm.userDictionary
        let result = await Task.detached(priority: .userInitiated) {
            SpellCheck.shared.unknownWords(in: snapshot, user: user)
        }.value
        findings = result
        scanning = false
    }
}
