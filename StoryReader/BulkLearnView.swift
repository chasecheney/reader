import SwiftUI

/// "Learn Words": scans the whole library for words the spell checker
/// doesn't know, aggregates them by how many stories they appear in, and
/// lets the user approve them into the personal dictionary in batches.
/// Ideal for seeding the dictionary with recurring character names.
struct BulkLearnView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    struct WordStat: Identifiable {
        var id: String { word }
        let word: String
        let files: Int        // distinct stories containing it
        let occurrences: Int
    }

    @State private var scanning = false
    @State private var scanDone = 0
    @State private var scanTotal = 0
    @State private var stats: [WordStat] = []
    @State private var selected: Set<String> = []
    @State private var minFiles = 3
    @State private var scanTask: Task<Void, Never>?

    private var shown: [WordStat] {
        Array(stats.lazy.filter { $0.files >= minFiles }.prefix(500))
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanning {
                    VStack(spacing: 12) {
                        ProgressView(value: Double(scanDone),
                                     total: Double(max(scanTotal, 1)))
                            .frame(maxWidth: 320)
                        Text("Scanning \(scanDone) of \(scanTotal) stories…")
                            .foregroundStyle(.secondary)
                        Button("Cancel") { cancelScan() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if stats.isEmpty {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Learn Words",
                            systemImage: "text.book.closed",
                            description: Text("Scan the whole library for words the spell checker doesn't know — recurring names and slang — and add them to your dictionary in one pass. Scanning \(vm.stories.count) stories takes a few minutes."))
                        Button("Start Scan") { startScan() }
                            .buttonStyle(.borderedProminent)
                            .disabled(vm.stories.isEmpty)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    results
                }
            }
            .navigationTitle("Learn Words")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { cancelScan(); dismiss() }
                }
                if !stats.isEmpty && !scanning {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(selected.count) Words") {
                            vm.addWordsToUserDictionary(Array(selected))
                            stats.removeAll { selected.contains($0.word) }
                            selected.removeAll()
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .onDisappear { cancelScan() }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 500)
        #endif
    }

    private var results: some View {
        List {
            Section {
                Stepper("Show words in at least \(minFiles) stories",
                        value: $minFiles, in: 1...100)
                HStack {
                    Button("Select All Shown") {
                        selected.formUnion(shown.map(\.word))
                    }
                    Button("Deselect All") { selected.removeAll() }
                    Spacer()
                    Text("\(shown.count) shown · \(stats.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .font(.callout)
            } footer: {
                Text("Words appearing in many stories are almost always real (names, slang). One-story words are usually typos — leave those unchecked; fix them with Edit → Check Spelling instead.")
            }

            Section {
                ForEach(shown) { s in
                    HStack {
                        Image(systemName: selected.contains(s.word)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(s.word)
                                             ? Color.accentColor : .secondary)
                        Text(s.word)
                        Spacer()
                        Text("\(s.files) stories · ×\(s.occurrences)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selected.contains(s.word) { selected.remove(s.word) }
                        else { selected.insert(s.word) }
                    }
                }
            }
        }
    }

    // MARK: - Scanning

    private func startScan() {
        scanning = true
        scanDone = 0
        stats = []
        selected = []
        let store = vm.store
        let user = vm.userDictionary

        scanTask = Task {
            let files = await Task.detached(priority: .userInitiated) {
                store.listStories(requestDownloads: false).filter(\.downloaded)
            }.value
            await MainActor.run { scanTotal = files.count }

            var fileCounts: [String: Int] = [:]
            var occurrences: [String: Int] = [:]
            var done = 0

            // Chunked so progress updates flow and cancellation is prompt.
            for chunk in stride(from: 0, to: files.count, by: 200).map({
                Array(files[$0..<min($0 + 200, files.count)])
            }) {
                if Task.isCancelled { return }
                let partial = await Task.detached(priority: .userInitiated) {
                    () -> [String: (Int, Int)] in
                    var out: [String: (Int, Int)] = [:]
                    for f in chunk {
                        guard let body = try? store.loadBody(at: f.url) else { continue }
                        for (w, n) in SpellCheck.shared.unknownCounts(in: body, user: user) {
                            let cur = out[w] ?? (0, 0)
                            out[w] = (cur.0 + 1, cur.1 + n)
                        }
                    }
                    return out
                }.value
                for (w, v) in partial {
                    fileCounts[w, default: 0] += v.0
                    occurrences[w, default: 0] += v.1
                }
                done += chunk.count
                await MainActor.run { scanDone = done }
            }

            let result = fileCounts.map {
                WordStat(word: $0.key, files: $0.value,
                         occurrences: occurrences[$0.key] ?? 0)
            }.sorted {
                $0.files != $1.files ? $0.files > $1.files : $0.word < $1.word
            }
            await MainActor.run {
                stats = result
                scanning = false
            }
        }
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }
}
