import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {

    let store = LibraryStore()
    private var index: SearchIndex?

    /// All stories keyed by stem.
    @Published private(set) var stories: [String: Story] = [:]
    /// Groups after filter + search, ready for display.
    @Published private(set) var groups: [SeriesGroup] = []
    @Published private(set) var tagCounts: [(tag: String, count: Int)] = []

    // Both didSets fire while SwiftUI is writing a binding (mid view-update),
    // so the dependent `groups` mutation must be deferred a runloop tick —
    // publishing other state synchronously there is undefined behavior.
    @Published var filter: LibraryFilter = .all { didSet { scheduleRebuild() } }
    @Published var searchText: String = "" { didSet { scheduleSearch() } }
    @Published var selectedStoryStem: String?

    // Status
    @Published var busy = false
    @Published var statusText: String?
    @Published var progressDone = 0
    @Published var progressTotal = 0
    @Published var usingICloud = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    /// Synced phrase → tag auto-tagging rules (see TagLibrary).
    @Published private(set) var tagRules: [TagRule] = []

    /// Synced personal spelling dictionary (see SpellCheck).
    @Published private(set) var userDictionary: Set<String> = []

    /// Unknown words collected during the last import, awaiting review
    /// (presented as a pre-populated Learn Words sheet; nil = nothing pending).
    @Published var pendingWordStats: [WordStat]?

    private var searchResults: Set<String>? = nil   // nil = no active search
    private var searchTask: Task<Void, Never>?
    private var userStates: [String: UserState] = [:]

    var selectedStory: Story? {
        selectedStoryStem.flatMap { stories[$0] }
    }

    // MARK: - Startup / refresh

    func start() async {
        do {
            let store = self.store
            try await Task.detached(priority: .userInitiated) {
                try store.bootstrap()
            }.value
            usingICloud = store.usingICloud
            tagRules = store.loadTagRules()
            userDictionary = store.loadUserDictionary()

            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            index = try SearchIndex(url: support
                .appendingPathComponent("StoryReader", isDirectory: true)
                .appendingPathComponent("index.sqlite"))

            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Scan the library folder, index new/changed files, prune deleted ones.
    func refresh() async {
        guard let index, !busy else { return }
        busy = true
        statusText = "Scanning library…"
        defer { busy = false; statusText = nil; progressTotal = 0 }

        let store = self.store
        let files = await Task.detached(priority: .utility) { store.listStories() }.value
        let stamps = await index.fileStamps()

        // Prune deleted files from the index.
        let currentStems = Set(files.map(\.stem))
        for stale in stamps.keys where !currentStems.contains(stale) {
            await index.remove(stem: stale)
        }

        // Which files need (re)indexing?
        let toIndex = files.filter { f in
            guard f.downloaded else { return false }
            guard let s = stamps[f.stem] else { return true }
            return s.size != f.size || abs(s.mtime - f.mtime.timeIntervalSince1970) > 1
        }

        if !toIndex.isEmpty {
            statusText = "Indexing \(toIndex.count) stories…"
            progressTotal = toIndex.count
            progressDone = 0

            // Progress flows back through an AsyncStream so the detached
            // worker never touches self (Swift 6 strict concurrency).
            let (progressStream, progressCont) = AsyncStream.makeStream(of: Int.self)
            let total = toIndex.count
            let worker = Task.detached(priority: .utility) {
                await index.beginBatch()
                var done = 0
                var pending = 0
                for f in toIndex {
                    done += 1
                    if let body = try? store.loadBody(at: f.url) {
                        let p = FilenameParser.parse(stem: f.stem)
                        let seriesKey = FilenameParser.baseTitle(p.title).lowercased()
                        await index.upsert(stem: f.stem,
                                           id: p.storyID ?? f.stem,
                                           title: p.title,
                                           seriesKey: seriesKey,
                                           tags: p.tags,
                                           size: f.size,
                                           mtime: f.mtime.timeIntervalSince1970,
                                           body: body)
                        pending += 1
                        if pending >= 500 {
                            await index.commitBatch()
                            await index.beginBatch()
                            pending = 0
                        }
                    }
                    if done % 20 == 0 || done == total {
                        progressCont.yield(done)
                    }
                }
                await index.commitBatch()
                progressCont.finish()
            }
            for await done in progressStream {
                progressDone = done
            }
            await worker.value
        }

        // Load user metadata and assemble the in-memory catalog.
        userStates = await Task.detached(priority: .utility) { store.loadAllUserStates() }.value
        let downloadedStems = Set(files.filter(\.downloaded).map(\.stem))
        let rows = await index.allRows()

        var dict: [String: Story] = [:]
        dict.reserveCapacity(rows.count)
        for r in rows {
            var story = Story(id: r.id, stem: r.stem, title: r.title,
                              seriesKey: r.seriesKey, fileTags: r.tags,
                              customTags: [], size: r.size,
                              modified: Date(timeIntervalSince1970: r.mtime),
                              downloaded: downloadedStems.contains(r.stem))
            if let us = userStates[r.id] {
                story.favorite = us.favorite
                story.isRead = us.read
                story.position = us.position
                story.customTags = us.customTags
                story.sortOrder = us.sortOrder
                story.seriesOverride = us.seriesOverride
            }
            dict[r.stem] = story
        }
        stories = dict
        rebuildGroups()
        rebuildTagCounts()

        let waiting = files.count - downloadedStems.count
        if waiting > 0 {
            statusText = "Waiting for iCloud to download \(waiting) files…"
        }
    }

    // MARK: - Grouping / filtering

    private func rebuildGroups() {
        var byKey: [String: [Story]] = [:]
        for s in stories.values where passesFilter(s) {
            byKey[s.effectiveSeriesKey, default: []].append(s)
        }
        var out: [SeriesGroup] = []
        out.reserveCapacity(byKey.count)
        for (key, list) in byKey {
            let sorted = Self.sortParts(list)
            let display = FilenameParser.baseTitle(sorted[0].title)
            out.append(SeriesGroup(id: key, title: display, stories: sorted))
        }
        out.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        groups = out
    }

    /// Manual sortOrder wins; parts without one follow, natural-sorted.
    static func sortParts(_ list: [Story]) -> [Story] {
        list.sorted { a, b in
            switch (a.sortOrder, b.sortOrder) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    private func passesFilter(_ s: Story) -> Bool {
        if let results = searchResults, !results.contains(s.stem) { return false }
        switch filter {
        case .all: return true
        case .favorites: return s.favorite
        case .unread: return !s.isRead
        case .tag(let t): return s.allTags.contains(t)
        }
    }

    private func rebuildTagCounts() {
        var counts: [String: Int] = [:]
        for s in stories.values {
            for t in s.allTags { counts[t, default: 0] += 1 }
        }
        tagCounts = counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.tag < $1.tag }
    }

    // MARK: - Search

    /// Rebuild groups on the next runloop tick, safely outside any in-flight
    /// view update (see note on `filter`/`searchText`).
    private func scheduleRebuild() {
        Task { @MainActor [weak self] in
            self?.rebuildGroups()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            searchResults = nil
            scheduleRebuild()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)   // debounce
            guard let self, let index = self.index, !Task.isCancelled else { return }
            let results = await index.search(text)
            guard !Task.isCancelled else { return }
            self.searchResults = results
            self.rebuildGroups()
        }
    }

    // MARK: - User actions

    func toggleFavorite(_ story: Story) {
        mutateState(of: story) { $0.favorite.toggle() }
    }

    func setRead(_ story: Story, _ read: Bool) {
        mutateState(of: story) { $0.read = read; if !read { $0.position = 0 } }
    }

    func savePosition(_ story: Story, fraction: Double) {
        // Avoid rewriting the synced metadata file on every scroll tick.
        let old = stories[story.stem]?.position ?? 0
        if abs(fraction - old) < 0.01 && fraction <= 0.92 { return }
        mutateState(of: story, rebuild: false) {
            $0.position = fraction
            if fraction > 0.92 { $0.read = true }
        }
    }

    func setCustomTags(_ story: Story, tags: [String]) {
        let clean = tags.map {
            $0.lowercased().trimmingCharacters(in: .whitespaces)
              .replacingOccurrences(of: "#", with: "")
              .replacingOccurrences(of: " ", with: "")
        }.filter { !$0.isEmpty }
        mutateState(of: story) { $0.customTags = Array(Set(clean)).sorted() }
        if let index, let s = stories[story.stem] {
            let all = Array(Set(s.fileTags + s.customTags)).sorted()
            Task { await index.updateTags(stem: story.stem, tags: all) }
        }
        rebuildTagCounts()
    }

    private func mutateState(of story: Story, rebuild: Bool = true,
                             _ change: (inout UserState) -> Void) {
        var state = userStates[story.id] ?? UserState()
        change(&state)
        userStates[story.id] = state

        if var s = stories[story.stem] {
            s.favorite = state.favorite
            s.isRead = state.read
            s.position = state.position
            s.customTags = state.customTags
            s.sortOrder = state.sortOrder
            s.seriesOverride = state.seriesOverride
            stories[story.stem] = s
        }
        let store = self.store
        let id = story.id
        let snapshot = state
        Task.detached(priority: .utility) { store.saveUserState(snapshot, for: id) }
        if rebuild { rebuildGroups() }
    }

    // MARK: - Tag library

    func setTagRules(_ rules: [TagRule]) {
        let clean = TagLibrary.cleaned(rules)
        tagRules = clean
        let store = self.store
        Task.detached(priority: .utility) { store.saveTagRules(clean) }
    }

    // MARK: - Editing & spelling

    /// Saves edited story text back to the library and re-indexes.
    /// Returns false (with errorMessage set) on failure.
    func saveStoryText(_ story: Story, text: String) async -> Bool {
        let store = self.store
        let stem = story.stem
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.saveBody(stem: stem, text: text)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        await refresh()   // picks up the size/mtime change, re-indexes this file
        return true
    }

    func addToUserDictionary(_ word: String) {
        addWordsToUserDictionary([word])
    }

    /// Bulk add (used by Learn Words) — one save for the whole batch.
    func addWordsToUserDictionary(_ words: [String]) {
        let clean = words
            .map { SpellCheck.normalize($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        userDictionary.formUnion(clean)
        let snapshot = userDictionary
        let store = self.store
        Task.detached(priority: .utility) { store.saveUserDictionary(snapshot) }
    }

    // MARK: - Import

    func importFiles(urls: [URL], autoTag: Bool = false,
                     collectWords: Bool = false) async {
        guard !busy else { return }
        busy = true
        statusText = "Importing…"
        progressDone = 0
        progressTotal = 0

        let store = self.store
        let rules = autoTag ? tagRules : []
        let userWords = userDictionary
        let (progressStream, progressCont) = AsyncStream.makeStream(of: (Int, Int).self)
        let worker = Task.detached(priority: .userInitiated) {
            let result = store.importFiles(from: urls, autoTagRules: rules,
                                           collectUnknownWords: collectWords,
                                           userWords: userWords) { done, total in
                progressCont.yield((done, total))
            }
            progressCont.finish()
            return result
        }
        for await (done, total) in progressStream {
            progressDone = done
            progressTotal = total
        }
        let result = await worker.value

        busy = false
        statusText = nil
        if result.failed > 0 {
            errorMessage = "\(result.failed) files failed to import."
        } else if result.tagged > 0 {
            infoMessage = "Imported \(result.imported) stories. \(result.tagged) were auto-tagged from the Tag Library."
        }
        if !result.unknownFiles.isEmpty {
            pendingWordStats = result.unknownFiles.map {
                WordStat(word: $0.key, files: $0.value,
                         occurrences: result.unknownOccurrences[$0.key] ?? 0)
            }.sorted {
                $0.files != $1.files ? $0.files > $1.files : $0.word < $1.word
            }
        }
        await refresh()
    }

    // MARK: - Library bundle (share / restore)

    /// Exports the whole library to a .storybundle file in the temporary
    /// directory and returns its URL (present it with a file mover / share).
    func exportBundle() async -> URL? {
        guard !busy else { return nil }
        busy = true
        statusText = "Exporting library bundle…"
        progressDone = 0
        progressTotal = 0
        defer { busy = false; statusText = nil; progressTotal = 0 }

        let store = self.store
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let name = "Story Library \(df.string(from: Date())).\(LibraryBundle.fileExtension)"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)

        let (progressStream, progressCont) = AsyncStream.makeStream(of: (Int, Int).self)
        let worker = Task.detached(priority: .userInitiated) { () -> Result<LibraryBundle.ExportResult, Error> in
            defer { progressCont.finish() }
            do {
                let r = try LibraryBundle.export(store: store, to: dest) { done, total in
                    progressCont.yield((done, total))
                }
                return .success(r)
            } catch {
                return .failure(error)
            }
        }
        for await (done, total) in progressStream {
            progressDone = done
            progressTotal = total
        }
        switch await worker.value {
        case .success(let r):
            var note = "Exported \(r.exported) stories (\(Int(r.totalBytes).byteString))."
            if r.skippedNotDownloaded > 0 {
                note += " \(r.skippedNotDownloaded) not yet downloaded from iCloud were left out — refresh and re-export later for a complete bundle."
            }
            infoMessage = note
            return dest
        case .failure(let error):
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Imports (merges) a .storybundle into the library, then re-indexes.
    func importBundle(url: URL) async {
        guard !busy else { return }
        busy = true
        statusText = "Importing library bundle…"
        progressDone = 0
        progressTotal = 0

        let store = self.store
        let (progressStream, progressCont) = AsyncStream.makeStream(of: (Int, Int).self)
        let worker = Task.detached(priority: .userInitiated) { () -> Result<LibraryBundle.ImportResult, Error> in
            defer { progressCont.finish() }
            do {
                let r = try LibraryBundle.import(store: store, from: url) { done, total in
                    progressCont.yield((done, total))
                }
                return .success(r)
            } catch {
                return .failure(error)
            }
        }
        for await (done, total) in progressStream {
            progressDone = done
            progressTotal = total
        }
        let outcome = await worker.value

        busy = false
        statusText = nil
        progressTotal = 0

        switch outcome {
        case .success(let r):
            var note = "Import finished: \(r.added) added, \(r.updated) updated, \(r.skipped) already present."
            if r.failed > 0 { note += " \(r.failed) failed." }
            infoMessage = note
            await refresh()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Part navigation

    func group(containing story: Story) -> SeriesGroup? {
        let key = story.effectiveSeriesKey
        return groups.first { $0.id == key }
        ?? SeriesGroup(id: key,
                       title: FilenameParser.baseTitle(story.title),
                       stories: Self.sortParts(stories.values
                           .filter { $0.effectiveSeriesKey == key }))
    }

    // MARK: - Manual series ordering

    /// Persist a user-chosen order for a series' parts (syncs like other state).
    func setSeriesOrder(orderedStems: [String]) {
        for (i, stem) in orderedStems.enumerated() {
            if let s = stories[stem] {
                mutateState(of: s, rebuild: false) { $0.sortOrder = i }
            }
        }
        rebuildGroups()
    }

    /// Back to automatic natural sorting for a series.
    func resetSeriesOrder(_ group: SeriesGroup) {
        for s in group.stories where s.sortOrder != nil {
            mutateState(of: s, rebuild: false) { $0.sortOrder = nil }
        }
        rebuildGroups()
    }

    // MARK: - Manual series membership

    /// Move a story into another series (key), or nil for automatic.
    func setSeriesOverride(_ story: Story, key: String?) {
        mutateState(of: story) { $0.seriesOverride = key }
    }

    /// Detach a story from its series so it stands alone.
    func detachFromSeries(_ story: Story) {
        setSeriesOverride(story, key: "solo:" + story.stem.lowercased())
    }

    /// All series in the library (unfiltered), for the series picker.
    func seriesChoices() -> [(key: String, title: String, count: Int)] {
        var first: [String: String] = [:]   // key -> best (natural-min) title
        var counts: [String: Int] = [:]
        for s in stories.values {
            let k = s.effectiveSeriesKey
            counts[k, default: 0] += 1
            if let t = first[k] {
                if s.title.localizedStandardCompare(t) == .orderedAscending {
                    first[k] = s.title
                }
            } else {
                first[k] = s.title
            }
        }
        return counts.keys.map { k in
            (key: k,
             title: FilenameParser.baseTitle(first[k] ?? k),
             count: counts[k] ?? 0)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Delete everything (testing / reset)

    func deleteAllData() async {
        guard !busy else { return }
        busy = true
        statusText = "Deleting library…"
        let store = self.store
        await Task.detached(priority: .userInitiated) { store.deleteAllFiles() }.value
        await index?.clear()
        userStates = [:]
        stories = [:]
        selectedStoryStem = nil
        searchText = ""
        rebuildGroups()
        rebuildTagCounts()
        busy = false
        statusText = nil
    }

    func neighbor(of story: Story, offset: Int) -> Story? {
        guard let g = group(containing: story),
              let i = g.stories.firstIndex(where: { $0.stem == story.stem }) else { return nil }
        let j = i + offset
        guard g.stories.indices.contains(j) else { return nil }
        return g.stories[j]
    }

    /// First part of the previous/next story (series) in the current list.
    func adjacentSeries(from story: Story, offset: Int) -> Story? {
        guard let gi = groups.firstIndex(where: { $0.id == story.effectiveSeriesKey }) else {
            return nil
        }
        let j = gi + offset
        guard groups.indices.contains(j) else { return nil }
        return groups[j].stories.first
    }
}
