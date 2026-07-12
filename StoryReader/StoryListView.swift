import SwiftUI

struct StoryListView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Binding var showImporter: Bool
    @State private var tagEditorStory: Story?
    @State private var reorderGroup: SeriesGroup?
    @State private var seriesPickerStory: Story?
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy: proxy)
        }
    }

    private func list(proxy: ScrollViewProxy) -> some View {
        List(selection: $vm.selectedStoryStem) {
            ForEach(vm.groups) { group in
                if group.stories.count == 1 {
                    StoryRow(story: group.stories[0], showPartTitle: false)
                        .tag(group.stories[0].stem)
                        .id(group.stories[0].stem)
                        .contextMenu { menu(for: group.stories[0]) }
                } else {
                    DisclosureGroup(isExpanded: isExpanded(group.id)) {
                        ForEach(group.stories) { story in
                            StoryRow(story: story, showPartTitle: true)
                                .tag(story.stem)
                                .id(story.stem)
                                .contextMenu { menu(for: story) }
                        }
                    } label: {
                        SeriesRow(group: group)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Clicking a series opens it and starts at
                                // its first part.
                                withAnimation {
                                    _ = expandedGroups.insert(group.id)
                                }
                                vm.selectedStoryStem = group.stories.first?.stem
                            }
                            .contextMenu {
                                Button("Reorder Parts…") { reorderGroup = group }
                                if group.stories.contains(where: { $0.sortOrder != nil }) {
                                    Button("Reset to Automatic Order") {
                                        vm.resetSeriesOrder(group)
                                    }
                                }
                            }
                    }
                }
            }
            // At 344k stories the full list can't be a single SwiftUI List —
            // rows beyond the cap are reachable via search/filter instead.
            if vm.totalGroupCount > LibraryViewModel.displayCap {
                Section {
                    Label("Showing the first \(LibraryViewModel.displayCap.formatted()) of \(vm.totalGroupCount.formatted()) stories — search or pick a tag to narrow down.",
                          systemImage: "line.3.horizontal.decrease.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $vm.searchText,
                    prompt: "Search — use \"exact phrase\", AND, OR")
        .navigationTitle(vm.filter.label)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if vm.groups.isEmpty && !vm.busy {
                if vm.stories.isEmpty {
                    ContentUnavailableView("No Stories Yet",
                                           systemImage: "tray",
                                           description: Text("Tap + in the sidebar to import .txt files or a folder."))
                } else {
                    ContentUnavailableView.search
                }
            }
        }
        .sheet(item: $tagEditorStory) { story in
            TagEditorView(story: story)
        }
        .sheet(item: $reorderGroup) { group in
            ReorderPartsView(group: group)
        }
        .sheet(item: $seriesPickerStory) { story in
            SeriesPickerView(story: story)
        }
        // Whenever the selection changes — reader part-navigation, next/prev
        // series, search, or programmatic — make sure the selected story is
        // actually visible: expand its series and scroll to it.
        .onChange(of: vm.selectedStoryStem) { _, stem in
            reveal(stem, proxy: proxy)
        }
        .onAppear {
            reveal(vm.selectedStoryStem, proxy: proxy)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import Stories", systemImage: "plus")
                }
                .disabled(vm.busy)

                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(vm.busy)
            }
        }
        #endif
    }

    /// Expand the selected story's series (if collapsed) and scroll the row
    /// into view. `anchor: nil` scrolls minimally, so clicking an
    /// already-visible row never jolts the list.
    private func reveal(_ stem: String?, proxy: ScrollViewProxy) {
        guard let stem, let story = vm.stories[stem] else { return }
        let key = story.effectiveSeriesKey
        let wasCollapsed = !expandedGroups.contains(key)
        if wasCollapsed {
            withAnimation { _ = expandedGroups.insert(key) }
        }
        // If we just expanded, wait a tick so the disclosure's rows exist
        // before scrolling to one of them.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasCollapsed ? 0.3 : 0)) {
            withAnimation { proxy.scrollTo(stem, anchor: nil) }
        }
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { open in
                if open { expandedGroups.insert(id) }
                else { expandedGroups.remove(id) }
            })
    }

    @ViewBuilder
    private func menu(for story: Story) -> some View {
        Button(story.favorite ? "Remove Favorite" : "Add to Favorites") {
            vm.toggleFavorite(story)
        }
        Button(story.isRead ? "Mark as Unread" : "Mark as Read") {
            vm.setRead(story, !story.isRead)
        }
        Button("Edit Tags…") {
            tagEditorStory = story
        }
        Divider()
        Button("Move to Series…") {
            seriesPickerStory = story
        }
        if (vm.group(containing: story)?.stories.count ?? 1) > 1 {
            Button("Detach from Series") {
                vm.detachFromSeries(story)
            }
        }
        if story.seriesOverride != nil {
            Button("Reset Series to Automatic") {
                vm.setSeriesOverride(story, key: nil)
            }
        }
    }
}

/// Pick the series a story belongs to (synced, per-story override).
struct SeriesPickerView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    let story: Story

    @State private var search = ""
    /// Full series list, similarity-ranked ONCE when the sheet opens
    /// (the reference title never changes). The filter field then only
    /// substring-matches this pre-ranked, pre-lowercased array — the old
    /// per-render recompute walked 344k stories per keystroke.
    @State private var ranked: [(key: String, title: String, lower: String, count: Int)] = []
    @State private var loadingChoices = true

    private var choices: [(key: String, title: String, lower: String, count: Int)] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? ranked : ranked.filter { $0.lower.contains(q) }
        return Array(filtered.prefix(200))
    }

    private func loadChoices() async {
        let all = await vm.computeSeriesChoices()
        let reference = story.title
        let myKey = story.effectiveSeriesKey
        let result = await Task.detached(priority: .userInitiated) {
            all.filter { $0.key != myKey }
                .map { (choice: $0, score: Self.similarity(reference, $0.title)) }
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.choice.title < $1.choice.title
                }
                .map { (key: $0.choice.key, title: $0.choice.title,
                        lower: $0.choice.title.lowercased(), count: $0.choice.count) }
        }.value
        ranked = result
        loadingChoices = false
    }

    // MARK: - Title similarity (prefix + shared words)

    nonisolated private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }

        // Word overlap (Jaccard).
        let sa = Set(ta), sb = Set(tb)
        let jaccard = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)

        // Normalized common-prefix length — filename siblings share long
        // prefixes ("4 cousins 02a e" vs "4 cousins").
        let pa = ta.joined(separator: " "), pb = tb.joined(separator: " ")
        let prefixLen = zip(pa, pb).prefix { $0 == $1 }.count
        let prefix = Double(prefixLen) / Double(max(pa.count, pb.count))

        return 0.5 * jaccard + 0.5 * prefix
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if story.seriesOverride != nil {
                        Button("Reset to Automatic (from filename)") {
                            vm.setSeriesOverride(story, key: nil)
                            dismiss()
                        }
                    }
                    Button("Make Standalone Story") {
                        vm.detachFromSeries(story)
                        dismiss()
                    }
                } header: {
                    Text(story.title)
                }
                Section("Move into") {
                    TextField("Filter series…", text: $search)
                        .textFieldStyle(.roundedBorder)
                    if loadingChoices {
                        HStack { ProgressView(); Text("Loading series…").foregroundStyle(.secondary) }
                    }
                    ForEach(choices, id: \.key) { choice in
                        Button {
                            vm.setSeriesOverride(story, key: choice.key)
                            dismiss()
                        } label: {
                            HStack {
                                Text(choice.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(choice.count == 1 ? "1 part" : "\(choice.count) parts")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Move to Series")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await loadChoices() }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }
}

/// Drag-to-reorder the parts of a series whose automatic ordering is wrong.
/// The chosen order is saved to synced metadata (per-story sortOrder).
struct ReorderPartsView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    let group: SeriesGroup

    @State private var parts: [Story] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(parts) { story in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Text(story.title)
                                .lineLimit(2)
                        }
                    }
                    .onMove { from, to in
                        parts.move(fromOffsets: from, toOffset: to)
                    }
                } header: {
                    Text("Drag parts into reading order")
                } footer: {
                    Text("The order syncs to your other device. Use “Reset to Automatic Order” in the series’ context menu to undo.")
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle(group.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.setSeriesOrder(orderedStems: parts.map(\.stem))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { parts = group.stories }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }
}

struct SeriesRow: View {
    let group: SeriesGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(group.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if group.favorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            HStack(spacing: 6) {
                Text("\(group.stories.count) parts")
                if group.allRead {
                    Text("· Read")
                }
                Text(tagLine)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var tagLine: String {
        group.tags.prefix(6).map { "#\($0)" }.joined(separator: " ")
    }
}

struct StoryRow: View {
    let story: Story
    var showPartTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(story.title)
                    .fontWeight(showPartTitle ? .regular : .medium)
                    .lineLimit(2)
                if story.favorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if !story.downloaded {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if story.isRead {
                    Text("Read")
                } else if story.position > 0 {
                    Text("\(Int(story.position * 100))%")
                }
                Text(story.allTags.prefix(6).map { "#\($0)" }.joined(separator: " "))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Tag editor: every known tag in the library as a toggleable chip, plus a
/// field for brand-new tags. Filename tags show as locked (always applied).
struct TagEditorView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    let story: Story

    @State private var selected: Set<String> = []
    @State private var newTag = ""

    /// Library tags ∪ this story's tags, so freshly added ones appear too.
    private var knownTags: [String] {
        Set(vm.tagCounts.map(\.tag))
            .union(selected)
            .union(story.fileTags)
            .sorted()
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(story.title)
                    .font(.headline)
                    .lineLimit(2)

                if !story.fileTags.isEmpty {
                    (Text("From filename: ").foregroundStyle(.secondary)
                     + Text(story.fileTags.map { "#\($0)" }.joined(separator: "  ")))
                        .font(.callout)
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                              spacing: 8) {
                        ForEach(knownTags, id: \.self) { tag in
                            chip(tag)
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    TextField("New tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTag)
                    Button("Add", action: addTag)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .navigationTitle("Edit Tags")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        vm.setCustomTags(story, tags: Array(selected))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { selected = Set(story.customTags) }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    @ViewBuilder
    private func chip(_ tag: String) -> some View {
        let isFileTag = story.fileTags.contains(tag)
        let isOn = isFileTag || selected.contains(tag)
        Button {
            guard !isFileTag else { return }
            if selected.contains(tag) { selected.remove(tag) }
            else { selected.insert(tag) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isFileTag ? "lock.fill"
                                 : isOn ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text("#\(tag)")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn ? Color.accentColor.opacity(isFileTag ? 0.12 : 0.22)
                               : Color.secondary.opacity(0.10))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isFileTag ? 0.65 : 1)
        .help(isFileTag ? "From the filename — always applied" : "")
    }

    private func addTag() {
        let t = newTag.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "")
        if !t.isEmpty { selected.insert(t) }
        newTag = ""
    }
}
