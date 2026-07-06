import Foundation

/// A file found in the library folder.
struct StoryFile {
    let stem: String      // filename without ".lzfse" (keeps ".txt")
    let url: URL          // actual URL (may be an ".icloud" placeholder)
    let size: Int
    let mtime: Date
    let downloaded: Bool
}

enum LibraryError: LocalizedError {
    case notReady
    case downloadTimeout(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "The library folder is not available yet."
        case .downloadTimeout(let n): return "Timed out waiting for iCloud to download “\(n)”."
        case .unreadable(let n): return "Could not read “\(n)”."
        }
    }
}

/// Owns the shared library folder (iCloud container when available, local
/// Documents otherwise), compressed story files, and per-story user metadata.
final class LibraryStore: @unchecked Sendable {

    private(set) var storiesURL: URL?
    private(set) var userDataURL: URL?
    private(set) var rootURL: URL?
    private(set) var usingICloud = false

    private let fm = FileManager.default

    /// Must be called off the main thread (ubiquity lookup can block).
    func bootstrap() throws {
        let root: URL
        if let ubiq = fm.url(forUbiquityContainerIdentifier: nil) {
            root = ubiq.appendingPathComponent("Documents", isDirectory: true)
            usingICloud = true
        } else {
            root = try fm.url(for: .documentDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            usingICloud = false
        }
        let stories = root.appendingPathComponent("Stories", isDirectory: true)
        let userData = root.appendingPathComponent("UserData", isDirectory: true)
        try fm.createDirectory(at: stories, withIntermediateDirectories: true)
        try fm.createDirectory(at: userData, withIntermediateDirectories: true)
        storiesURL = stories
        userDataURL = userData
        rootURL = root
    }

    // MARK: - Tag library (synced phrase → tag rules)

    func loadTagRules() -> [TagRule] {
        guard let root = rootURL else { return [] }
        let url = root.appendingPathComponent(TagLibrary.filename)
        // On a fresh device the file may still be an iCloud placeholder —
        // request it and return nothing rather than seeding defaults over
        // rules that are about to sync down.
        let placeholder = root.appendingPathComponent("." + TagLibrary.filename + ".icloud")
        if fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: placeholder)
            return []
        }
        // No saved library anywhere: first launch → seed the default rules.
        // (An intentionally cleared library is saved as "[]", not deleted,
        // so defaults don't resurrect.)
        guard fm.fileExists(atPath: url.path) else {
            saveTagRules(TagLibrary.defaultRules)
            return TagLibrary.defaultRules
        }
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([TagRule].self, from: data) else { return [] }
        return rules
    }

    func saveTagRules(_ rules: [TagRule]) {
        guard let root = rootURL else { return }
        let url = root.appendingPathComponent(TagLibrary.filename)
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Listing

    /// Lists every story in the library, including not-yet-downloaded iCloud
    /// placeholders (named ".<name>.icloud"). Requests download of placeholders.
    func listStories(requestDownloads: Bool = true) -> [StoryFile] {
        guard let dir = storiesURL else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [StoryFile] = []
        out.reserveCapacity(items.count)

        // .skipsHiddenFiles hides ".Name.icloud" placeholders, so list those separately.
        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? items

        for url in all {
            let name = url.lastPathComponent
            if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                // iCloud placeholder: ".Title #tags (id).txt.lzfse.icloud"
                var stem = String(name.dropFirst().dropLast(".icloud".count))
                if stem.lowercased().hasSuffix(".lzfse") { stem = String(stem.dropLast(6)) }
                let rv = try? url.resourceValues(forKeys: Set(keys))
                out.append(StoryFile(stem: stem, url: url,
                                     size: rv?.fileSize ?? 0,
                                     mtime: rv?.contentModificationDate ?? .distantPast,
                                     downloaded: false))
                if requestDownloads {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                }
            } else if name.hasPrefix(".") {
                continue
            } else if name.lowercased().hasSuffix(".lzfse") || name.lowercased().hasSuffix(".txt") {
                var stem = name
                if stem.lowercased().hasSuffix(".lzfse") { stem = String(stem.dropLast(6)) }
                let rv = try? url.resourceValues(forKeys: Set(keys))
                out.append(StoryFile(stem: stem, url: url,
                                     size: rv?.fileSize ?? 0,
                                     mtime: rv?.contentModificationDate ?? .distantPast,
                                     downloaded: true))
            }
        }
        return out
    }

    // MARK: - Reading

    /// Loads and decompresses the body text for a story stem.
    /// If the file is an un-downloaded iCloud item, requests the download and
    /// waits up to `timeout` seconds.
    func loadBody(stem: String, timeout: TimeInterval = 20) throws -> String {
        guard let dir = storiesURL else { throw LibraryError.notReady }
        let compressed = dir.appendingPathComponent(stem + ".lzfse")
        let plain = dir.appendingPathComponent(stem)

        var target: URL? = nil
        if fm.fileExists(atPath: compressed.path) { target = compressed }
        else if fm.fileExists(atPath: plain.path) { target = plain }
        else {
            // Maybe still an iCloud placeholder — ask for it and wait.
            for candidate in [compressed, plain] {
                let placeholder = dir.appendingPathComponent("." + candidate.lastPathComponent + ".icloud")
                if fm.fileExists(atPath: placeholder.path) {
                    try? fm.startDownloadingUbiquitousItem(at: placeholder)
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        if fm.fileExists(atPath: candidate.path) { target = candidate; break }
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                    break
                }
            }
        }
        guard let url = target else { throw LibraryError.downloadTimeout(stem) }
        return try loadBody(at: url)
    }

    /// Loads and (if needed) decompresses a downloaded file directly.
    func loadBody(at url: URL) throws -> String {
        let raw = try Data(contentsOf: url)
        let data: Data
        if url.lastPathComponent.lowercased().hasSuffix(".lzfse") {
            data = try (raw as NSData).decompressed(using: .lzfse) as Data
        } else {
            data = raw
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw LibraryError.unreadable(url.lastPathComponent)
    }

    // MARK: - Importing

    struct ImportResult { var imported = 0; var skipped = 0; var failed = 0; var tagged = 0 }

    /// Imports .txt files (or folders of them). Files are LZFSE-compressed
    /// into the library. Existing files are skipped.
    ///
    /// When `autoTagRules` is non-empty, each newly imported story's text is
    /// scanned with the Tag Library and matched tags (that aren't already in
    /// the filename) are saved into the story's synced custom-tag metadata.
    func importFiles(from urls: [URL], autoTagRules: [TagRule] = [],
                     progress: @escaping (Int, Int) -> Void) -> ImportResult {
        guard let dir = storiesURL else { return ImportResult() }
        var result = ImportResult()

        let matcher = TagLibrary.Matcher(rules: autoTagRules)
        // Existing metadata, loaded once so auto-tagging merges instead of clobbering.
        var states: [String: UserState] = matcher.isEmpty ? [:] : loadAllUserStates()

        // Expand folders.
        var fileURLs: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let f as URL in en where f.pathExtension.lowercased() == "txt" {
                        fileURLs.append(f)
                    }
                }
            } else if url.pathExtension.lowercased() == "txt" {
                fileURLs.append(url)
            }

            let total = fileURLs.count
            var done = 0
            for f in fileURLs {
                autoreleasepool {
                    let dest = dir.appendingPathComponent(f.lastPathComponent + ".lzfse")
                    if fm.fileExists(atPath: dest.path) {
                        result.skipped += 1
                    } else {
                        do {
                            let raw = try Data(contentsOf: f)
                            let packed = try (raw as NSData).compressed(using: .lzfse) as Data
                            try packed.write(to: dest, options: .atomic)
                            result.imported += 1

                            // Auto-tag from the Tag Library.
                            if !matcher.isEmpty,
                               let text = String(data: raw, encoding: .utf8)
                                       ?? String(data: raw, encoding: .isoLatin1) {
                                let parsed = FilenameParser.parse(stem: f.lastPathComponent)
                                let found = matcher.tags(in: text)
                                    .subtracting(parsed.tags)   // filename tags already apply
                                if !found.isEmpty {
                                    let id = parsed.storyID ?? f.lastPathComponent
                                    var state = states[id] ?? UserState()
                                    let merged = Set(state.customTags).union(found)
                                    if merged != Set(state.customTags) {
                                        state.customTags = Array(merged).sorted()
                                        states[id] = state
                                        saveUserState(state, for: id)
                                        result.tagged += 1
                                    }
                                }
                            }
                        } catch {
                            result.failed += 1
                        }
                    }
                    done += 1
                    if done % 50 == 0 || done == total { progress(done, total) }
                }
            }
            fileURLs.removeAll()
        }
        return result
    }

    // MARK: - Deleting (testing / reset)

    /// Removes every story file and every piece of user metadata from the
    /// library. On iCloud, deletions propagate to the other device.
    func deleteAllFiles() {
        for dir in [storiesURL, userDataURL].compactMap({ $0 }) {
            let items = (try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: nil)) ?? []
            for url in items {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - User state (synced per-story JSON)

    func loadAllUserStates() -> [String: UserState] {
        guard let dir = userDataURL else { return [:] }
        var out: [String: UserState] = [:]
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                try? fm.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            let id = String(name.dropLast(5))
            if let data = try? Data(contentsOf: url),
               let st = try? dec.decode(UserState.self, from: data) {
                out[id] = st
            }
        }
        return out
    }

    func saveUserState(_ state: UserState, for id: String) {
        guard let dir = userDataURL else { return }
        let url = dir.appendingPathComponent(id + ".json")
        if state.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
