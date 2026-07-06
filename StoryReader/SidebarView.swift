import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var showDeleteConfirm = false
    @State private var showTagLibrary = false

    var body: some View {
        List(selection: Binding<LibraryFilter?>(
            get: { vm.filter },
            set: { vm.filter = $0 ?? .all })) {

            Section("Library") {
                Label("All Stories", systemImage: "books.vertical")
                    .tag(LibraryFilter.all)
                Label("Favorites", systemImage: "star")
                    .tag(LibraryFilter.favorites)
                Label("Unread", systemImage: "circle")
                    .tag(LibraryFilter.unread)
            }

            Section("Tags") {
                ForEach(vm.tagCounts, id: \.tag) { item in
                    HStack {
                        Label("#\(item.tag)", systemImage: "tag")
                        Spacer()
                        Text("\(item.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(LibraryFilter.tag(item.tag))
                }
            }

            Section("Settings") {
                Button {
                    showTagLibrary = true
                } label: {
                    HStack {
                        Label("Tag Library…", systemImage: "tag.square")
                        Spacer()
                        if !vm.tagRules.isEmpty {
                            Text("\(vm.tagRules.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .help("Word/phrase → tag rules used to auto-tag stories on import")
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete All Stories…", systemImage: "trash")
                }
                .disabled(vm.busy || vm.stories.isEmpty)
            }
        }
        .sheet(isPresented: $showTagLibrary) {
            TagLibraryView()
                .environmentObject(vm)
        }
        .confirmationDialog(
            "Delete all \(vm.stories.count) stories?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task { await vm.deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every story file, all favorites, read status, reading positions, and custom tags from the library\(vm.usingICloud ? " on all devices" : ""). This cannot be undone.")
        }
        .navigationTitle("Story Reader")
        // NOTE: Import/Refresh intentionally live in ContentView's detail
        // toolbar — sidebar-column toolbar items are unreliably restored by
        // macOS when the split-view structure changes (story-list toggle).
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = vm.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if vm.progressTotal > 0 {
                    ProgressView(value: Double(vm.progressDone),
                                 total: Double(vm.progressTotal))
                        .progressViewStyle(.linear)
                }
            } else {
                Text("\(vm.stories.count) files · \(vm.usingICloud ? "iCloud" : "Local only")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.bar)
    }
}
