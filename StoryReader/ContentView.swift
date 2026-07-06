import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var showImporter = false
    @State private var showBundleImporter = false
    @State private var bundleExportURL: URL?
    @State private var showBundleMover = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The shareable library bundle file type (.storybundle).
    private static let bundleType = UTType(filenameExtension: LibraryBundle.fileExtension) ?? .data

    #if os(macOS)
    // macOS can't collapse the middle column via columnVisibility, so the
    // list column is added/removed structurally.
    @State private var showStoryList = true
    #else
    // iPadOS collapses columns natively; remember the sidebar's state so
    // re-showing the list doesn't also re-open the sidebar.
    @State private var sidebarWasVisible = true
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            if showStoryList {
                threeColumn
            } else {
                twoColumn
            }
            #else
            threeColumn
            #endif
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.plainText, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await vm.importFiles(urls: urls) }
            }
        }
        .alert("Story Reader", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("Library Bundle", isPresented: Binding(
            get: { vm.infoMessage != nil },
            set: { if !$0 { vm.infoMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.infoMessage ?? "")
        }
    }

    // MARK: - Split views

    private var threeColumn: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            StoryListView(showImporter: $showImporter)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            detailPane
        }
    }

    #if os(macOS)
    private var twoColumn: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailPane
        }
    }
    #endif

    private var sidebar: some View {
        SidebarView()
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    // MARK: - Story-list toggle

    private var listHidden: Bool {
        #if os(macOS)
        return !showStoryList
        #else
        return columnVisibility == .detailOnly
        #endif
    }

    private func toggleStoryList() {
        #if os(macOS)
        // columnVisibility means different things in 2- vs 3-column layouts,
        // so translate it to keep the sidebar's state:
        // 3-col: .all = sidebar shown, .doubleColumn = sidebar hidden
        // 2-col: .all/.doubleColumn = sidebar shown, .detailOnly = hidden
        let sidebarHidden = showStoryList
            ? (columnVisibility == .doubleColumn || columnVisibility == .detailOnly)
            : (columnVisibility == .detailOnly)
        if showStoryList {
            columnVisibility = sidebarHidden ? .detailOnly : .all
        } else {
            columnVisibility = sidebarHidden ? .doubleColumn : .all
        }
        showStoryList.toggle()
        #else
        withAnimation {
            if columnVisibility == .detailOnly {
                // Restore the list; only bring the sidebar back if it was
                // visible when the list was hidden.
                columnVisibility = sidebarWasVisible ? .all : .doubleColumn
            } else {
                sidebarWasVisible = (columnVisibility == .all)
                columnVisibility = .detailOnly
            }
        }
        #endif
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let story = vm.selectedStory {
                ReaderView(story: story)
                    .id(story.stem)
            } else {
                ContentUnavailableView("Select a Story",
                                       systemImage: "book.closed",
                                       description: Text("Choose a story from the list, or import files with the + button."))
            }
        }
        .fileImporter(isPresented: $showBundleImporter,
                      allowedContentTypes: [Self.bundleType, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await vm.importBundle(url: url) }
            }
        }
        .fileMover(isPresented: $showBundleMover, file: bundleExportURL) { result in
            if case .failure(let error) = result {
                vm.errorMessage = error.localizedDescription
            }
            bundleExportURL = nil
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleStoryList()
                } label: {
                    Label(listHidden ? "Show Story List" : "Hide Story List",
                          systemImage: "sidebar.squares.left")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help(listHidden ? "Show the story list" : "Hide the story list")
            }

            // Library bundle: one-file share/restore of the whole library.
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        Task {
                            if let url = await vm.exportBundle() {
                                bundleExportURL = url
                                showBundleMover = true
                            }
                        }
                    } label: {
                        Label("Export Library Bundle…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(vm.busy || vm.stories.isEmpty)

                    Button {
                        showBundleImporter = true
                    } label: {
                        Label("Import Library Bundle…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(vm.busy)
                } label: {
                    Label("Library Bundle", systemImage: "shippingbox")
                }
                .help("Share the whole library as one file, or merge in a bundle from another device or user")
            }

            // macOS only: sidebar/list-column toolbar items get lost when the
            // split-view structure swaps, so they live here. On iPadOS they
            // belong to the story-list column (see StoryListView).
            #if os(macOS)
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import Stories", systemImage: "plus")
                }
                .disabled(vm.busy)
                .help("Import .txt files or a folder")

                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(vm.busy)
                .help("Re-scan the library")
            }
            #endif
        }
    }
}
