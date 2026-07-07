import Foundation

/// Single-file, shareable, compressed library bundle (".storybundle").
///
/// Purpose: package the whole story library (or any snapshot of it) into one
/// file that can be AirDropped / copied to another user or a fresh install,
/// where importing it merges the stories into the local library. Importing a
/// newer bundle over an existing library only writes what's new or changed,
/// so updates are incremental by nature.
///
/// File layout (little-endian):
///   bytes 0..<8    magic "STRYBNDL"
///   bytes 8..<12   format version (UInt32) — currently 1
///   bytes 12..<20  manifest JSON length (UInt64)
///   manifest JSON  (UTF-8, `BundleManifest`)
///   blob region    LZFSE-compressed story texts, back to back
///
/// Each blob is byte-identical to the library's on-disk ".lzfse" file, so
/// export and import stream bytes without ever recompressing. User metadata
/// (favorites, positions, custom tags) is deliberately NOT included — the
/// bundle carries content, not one person's reading state.
enum LibraryBundle {

    static let magic = Data("STRYBNDL".utf8)
    static let formatVersion: UInt32 = 1
    static let fileExtension = "storybundle"

    struct ManifestEntry: Codable {
        /// Filename inside the library without the ".lzfse" suffix,
        /// e.g. "Title, Part 2 #anal #oral (12345).txt"
        var stem: String
        /// Offset of the blob relative to the start of the blob region.
        var offset: UInt64
        /// Compressed blob size in bytes.
        var size: UInt64
        /// Source file modification time (secs since 1970) for update checks.
        var mtime: Double
    }

    struct BundleManifest: Codable {
        var formatVersion: Int = 1
        var created: Date = Date()
        var generator: String = "Story Reader"
        var storyCount: Int = 0
        var entries: [ManifestEntry] = []
        /// Optional: the exporter's personal spelling dictionary, so learned
        /// words (names, slang) travel with the library. Old readers ignore
        /// this key; old bundles simply don't have it.
        var userDictionary: [String]? = nil
    }

    enum BundleError: LocalizedError {
        case notABundle
        case unsupportedVersion(UInt32)
        case corrupt(String)
        case libraryNotReady

        var errorDescription: String? {
            switch self {
            case .notABundle:
                return "This file is not a Story Reader library bundle."
            case .unsupportedVersion(let v):
                return "This bundle uses format version \(v), which this version of the app can't read."
            case .corrupt(let detail):
                return "The bundle appears to be damaged (\(detail))."
            case .libraryNotReady:
                return "The library folder is not available yet."
            }
        }
    }

    struct ExportResult {
        var exported = 0
        var skippedNotDownloaded = 0
        var totalBytes: UInt64 = 0
    }

    struct ImportResult {
        var added = 0
        var updated = 0
        var skipped = 0
        var failed = 0
        /// Words merged into the local personal dictionary from the bundle.
        var learnedWords = 0
    }

    // MARK: - Export

    /// Streams the whole library into a bundle file at `dest`.
    /// Files that are still un-downloaded iCloud placeholders are skipped
    /// (and counted), never silently lost.
    static func export(store: LibraryStore, to dest: URL,
                       userWords: Set<String> = [],
                       progress: @escaping (Int, Int) -> Void) throws -> ExportResult {
        guard store.storiesURL != nil else { throw BundleError.libraryNotReady }
        let fm = FileManager.default

        let files = store.listStories(requestDownloads: false)
            .sorted { $0.stem.localizedStandardCompare($1.stem) == .orderedAscending }

        var result = ExportResult()

        // Pass 1: build the manifest. For plain .txt library files we must
        // compress to know the blob size; those (rare) compressed payloads are
        // kept for pass 2 so the work isn't done twice.
        var entries: [ManifestEntry] = []
        var inlineBlobs: [String: Data] = [:]   // stem -> compressed (txt-source files only)
        var offset: UInt64 = 0

        for f in files {
            guard f.downloaded else { result.skippedNotDownloaded += 1; continue }
            let name = f.url.lastPathComponent
            let size: UInt64
            if name.lowercased().hasSuffix(".lzfse") {
                let attrs = try? fm.attributesOfItem(atPath: f.url.path)
                size = (attrs?[.size] as? UInt64) ?? UInt64(f.size)
            } else {
                let raw = try Data(contentsOf: f.url)
                let packed = try (raw as NSData).compressed(using: .lzfse) as Data
                inlineBlobs[f.stem] = packed
                size = UInt64(packed.count)
            }
            entries.append(ManifestEntry(stem: f.stem, offset: offset, size: size,
                                         mtime: f.mtime.timeIntervalSince1970))
            offset += size
        }

        var manifest = BundleManifest()
        manifest.storyCount = entries.count
        manifest.entries = entries
        if !userWords.isEmpty {
            manifest.userDictionary = userWords.sorted()
        }

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let manifestData = try enc.encode(manifest)

        // Write header + manifest, then stream the blobs.
        fm.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }

        var header = Data()
        header.append(magic)
        header.append(withUnsafeBytes(of: formatVersion.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt64(manifestData.count).littleEndian) { Data($0) })
        try out.write(contentsOf: header)
        try out.write(contentsOf: manifestData)

        let byStem = Dictionary(uniqueKeysWithValues: files.map { ($0.stem, $0) })
        let total = entries.count
        for (i, e) in entries.enumerated() {
            try autoreleasepool {
                if let packed = inlineBlobs[e.stem] {
                    try out.write(contentsOf: packed)
                } else if let f = byStem[e.stem] {
                    // .lzfse library file: copy bytes as-is.
                    let blob = try Data(contentsOf: f.url, options: .alwaysMapped)
                    try out.write(contentsOf: blob)
                }
            }
            result.exported += 1
            if (i + 1) % 200 == 0 || i + 1 == total { progress(i + 1, total) }
        }
        result.totalBytes = 20 + UInt64(manifestData.count) + offset
        return result
    }

    // MARK: - Reading

    /// Reads and validates just the manifest (fast — no blobs touched).
    static func readManifest(at url: URL) throws -> (manifest: BundleManifest, blobStart: UInt64) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        guard let head = try fh.read(upToCount: 20), head.count == 20,
              head.prefix(8) == magic else { throw BundleError.notABundle }

        let version = head.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard version == formatVersion else { throw BundleError.unsupportedVersion(version) }

        let mlen = head.subdata(in: 12..<20).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard mlen > 0, mlen < 500_000_000 else { throw BundleError.corrupt("bad manifest length") }

        guard let mdata = try fh.read(upToCount: Int(mlen)), mdata.count == Int(mlen) else {
            throw BundleError.corrupt("truncated manifest")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let manifest = try? dec.decode(BundleManifest.self, from: mdata) else {
            throw BundleError.corrupt("unreadable manifest")
        }
        return (manifest, 20 + mlen)
    }

    // MARK: - Import

    /// Merges a bundle into the library:
    ///   - story not in the library      -> added
    ///   - present, bundle newer+differs -> updated (overwritten)
    ///   - otherwise                     -> skipped
    /// Never touches user metadata. Safe to re-import the same bundle
    /// (idempotent) and safe to import a newer bundle over an older library.
    static func `import`(store: LibraryStore, from url: URL,
                         progress: @escaping (Int, Int) -> Void) throws -> ImportResult {
        guard let libDir = store.storiesURL else { throw BundleError.libraryNotReady }
        let fm = FileManager.default

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let (manifest, blobStart) = try readManifest(at: url)

        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var result = ImportResult()
        let total = manifest.entries.count

        for (i, e) in manifest.entries.enumerated() {
            autoreleasepool {
                let dest = libDir.appendingPathComponent(e.stem + ".lzfse")
                let plain = libDir.appendingPathComponent(e.stem)
                let placeholder = libDir.appendingPathComponent("." + e.stem + ".lzfse.icloud")

                var action = "add"
                if fm.fileExists(atPath: dest.path) {
                    let attrs = try? fm.attributesOfItem(atPath: dest.path)
                    let localSize = (attrs?[.size] as? UInt64) ?? 0
                    let localM = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    if localSize == e.size {
                        action = "skip"                       // identical content
                    } else if e.mtime > localM {
                        action = "update"                     // bundle is newer
                    } else {
                        action = "skip"                       // local is newer
                    }
                } else if fm.fileExists(atPath: plain.path) || fm.fileExists(atPath: placeholder.path) {
                    action = "skip"   // present uncompressed or syncing down
                }

                switch action {
                case "skip":
                    result.skipped += 1
                default:
                    do {
                        try fh.seek(toOffset: blobStart + e.offset)
                        guard let blob = try fh.read(upToCount: Int(e.size)),
                              blob.count == Int(e.size) else {
                            result.failed += 1; break
                        }
                        // Cheap integrity check: LZFSE blobs start with "bvx".
                        guard blob.count >= 4, blob.prefix(3) == Data("bvx".utf8) else {
                            result.failed += 1; break
                        }
                        try blob.write(to: dest, options: .atomic)
                        if action == "update" { result.updated += 1 } else { result.added += 1 }
                    } catch {
                        result.failed += 1
                    }
                }
            }
            if (i + 1) % 200 == 0 || i + 1 == total { progress(i + 1, total) }
        }

        // Merge the bundle's spelling dictionary (if any) into ours.
        if let bundleWords = manifest.userDictionary, !bundleWords.isEmpty {
            let mine = store.loadUserDictionary()
            let merged = mine.union(bundleWords)
            if merged.count > mine.count {
                store.saveUserDictionary(merged)
                result.learnedWords = merged.count - mine.count
            }
        }
        return result
    }
}
