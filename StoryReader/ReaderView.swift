import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias PlatformScrollView = NSScrollView
#else
typealias PlatformScrollView = UIScrollView
#endif

/// Finds the platform scroll view backing the SwiftUI ScrollView it sits in,
/// so auto-scroll can move it continuously (teleprompter-style) instead of
/// jumping paragraph by paragraph.
private struct ScrollViewGrabber: PlatformViewRepresentable {
    var onResolve: (PlatformScrollView?) -> Void

    #if os(macOS)
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v.enclosingScrollView) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.enclosingScrollView) }
    }
    #else
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        DispatchQueue.main.async { onResolve(Self.enclosingScrollView(of: v)) }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { onResolve(Self.enclosingScrollView(of: uiView)) }
    }
    static func enclosingScrollView(of view: UIView) -> UIScrollView? {
        var v = view.superview
        while let cur = v {
            if let sv = cur as? UIScrollView { return sv }
            v = cur.superview
        }
        return nil
    }
    #endif
}

#if os(macOS)
private protocol PlatformViewRepresentable: NSViewRepresentable {}
#else
private protocol PlatformViewRepresentable: UIViewRepresentable {}
#endif

struct ReaderView: View {
    @EnvironmentObject var vm: LibraryViewModel
    let story: Story

    @AppStorage("readerFontSize") private var fontSize: Double = 17
    @AppStorage("readerSerif") private var serif = true
    @AppStorage("readerTheme") private var themeRaw = ReaderTheme.system.rawValue

    @State private var paragraphs: [String] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var scrolledID: Int?
    @State private var restored = false

    // Auto-scroll
    @AppStorage("readerScrollSpeed") private var scrollSpeed = 1.0   // 0.25×–4×
    @State private var showAutoScroll = false
    @State private var autoScrolling = false
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var platformScrollView: PlatformScrollView?
    @State private var fallbackAccum: CGFloat = 0

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .system }
    private var current: Story { vm.stories[story.stem] ?? story }

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Couldn’t Open Story",
                                       systemImage: "exclamationmark.icloud",
                                       description: Text(loadError))
            } else {
                readerScroll
            }
        }
        .background(theme.background ?? Color.clear)
        .navigationTitle(current.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if showAutoScroll { autoScrollBar }
        }
        .task(id: story.stem) { await load() }
        .onDisappear {
            stopAutoScroll()
            savePosition()
        }
    }

    private var readerScroll: some View {
        // Explicit column width from the measured pane size: if the column is
        // still animating when the story loads, the text re-wraps as soon as
        // the size settles (otherwise LazyVStack keeps the stale layout until
        // the user scrolls).
        GeometryReader { geo in
            let columnWidth = min(760, geo.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: fontSize * 0.9) {
                    ForEach(paragraphs.indices, id: \.self) { i in
                        Text(paragraphs[i])
                            .font(.system(size: fontSize,
                                          design: serif ? .serif : .default))
                            .lineSpacing(fontSize * 0.32)
                            .foregroundStyle(theme.foreground ?? Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                    partFooter
                }
                .scrollTargetLayout()
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(width: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background(ScrollViewGrabber { sv in
                    if platformScrollView !== sv { platformScrollView = sv }
                })
            }
            .scrollPosition(id: $scrolledID, anchor: .top)
            .onChange(of: scrolledID) {
                if restored { savePosition() }
            }
        }
    }

    @ViewBuilder
    private var partFooter: some View {
        if let next = vm.neighbor(of: current, offset: 1) {
            Button {
                vm.selectedStoryStem = next.stem
            } label: {
                Label("Next: \(next.title)", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 24)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // << previous story/series
            Button {
                if let prev = vm.adjacentSeries(from: current, offset: -1) {
                    vm.selectedStoryStem = prev.stem
                }
            } label: {
                Label("Previous Story", systemImage: "chevron.backward.2")
            }
            .disabled(vm.adjacentSeries(from: current, offset: -1) == nil)
            .help("Previous story")

            if let prev = vm.neighbor(of: current, offset: -1) {
                Button {
                    vm.selectedStoryStem = prev.stem
                } label: {
                    Label("Previous Part", systemImage: "chevron.backward")
                }
                .help(prev.title)
            }
            if let next = vm.neighbor(of: current, offset: 1) {
                Button {
                    vm.selectedStoryStem = next.stem
                } label: {
                    Label("Next Part", systemImage: "chevron.forward")
                }
                .help(next.title)
            }

            // >> next story/series
            Button {
                if let next = vm.adjacentSeries(from: current, offset: 1) {
                    vm.selectedStoryStem = next.stem
                }
            } label: {
                Label("Next Story", systemImage: "chevron.forward.2")
            }
            .disabled(vm.adjacentSeries(from: current, offset: 1) == nil)
            .help("Next story")

            Button {
                showAutoScroll.toggle()
                if !showAutoScroll { stopAutoScroll() }
            } label: {
                Label("Auto-Scroll",
                      systemImage: showAutoScroll
                          ? "arrow.down.to.line.circle.fill"
                          : "arrow.down.to.line.circle")
            }
            .help("Show auto-scroll controls")

            Button {
                vm.toggleFavorite(current)
            } label: {
                Label("Favorite",
                      systemImage: current.favorite ? "star.fill" : "star")
            }

            Menu {
                Section("Text Size") {
                    Button("Smaller") { fontSize = max(12, fontSize - 1) }
                        .keyboardShortcut("-", modifiers: [.command])
                    Button("Larger") { fontSize = min(32, fontSize + 1) }
                        .keyboardShortcut("+", modifiers: [.command])
                }
                Section("Font") {
                    Picker("Font", selection: $serif) {
                        Text("Serif").tag(true)
                        Text("Sans-serif").tag(false)
                    }
                }
                Section("Theme") {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(ReaderTheme.allCases) { t in
                            Text(t.label).tag(t.rawValue)
                        }
                    }
                }
                Section {
                    Button(current.isRead ? "Mark as Unread" : "Mark as Read") {
                        vm.setRead(current, !current.isRead)
                    }
                }
            } label: {
                Label("Reading Options", systemImage: "textformat.size")
            }
        }
    }

    // MARK: - Auto-scroll

    private var autoScrollBar: some View {
        HStack(spacing: 12) {
            Button {
                if autoScrolling { stopAutoScroll() } else { startAutoScroll() }
            } label: {
                Image(systemName: autoScrolling ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(autoScrolling ? "Pause auto-scroll" : "Start auto-scroll")

            Image(systemName: "tortoise")
                .foregroundStyle(.secondary)
            Slider(value: $scrollSpeed, in: 0.25...4, step: 0.25)
                .frame(maxWidth: 320)
            Image(systemName: "hare")
                .foregroundStyle(.secondary)

            Text(String(format: "%.2g×", scrollSpeed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Points per second at 1× — roughly comfortable reading speed.
    private static let baseSpeed: Double = 50

    private func startAutoScroll() {
        guard !autoScrolling, !paragraphs.isEmpty else { return }
        autoScrolling = true
        autoScrollTask = Task { @MainActor in
            var last = ContinuousClock.now
            while autoScrolling && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)   // ~60 fps
                let now = ContinuousClock.now
                let comps = (now - last).components
                let dt = Double(comps.seconds) + Double(comps.attoseconds) / 1e18
                last = now
                stepAutoScroll(by: CGFloat(Self.baseSpeed * scrollSpeed * dt))
            }
        }
    }

    /// Teleprompter step: move the platform scroll view's offset directly for
    /// perfectly smooth motion. Falls back to paragraph stepping if the
    /// scroll view couldn't be resolved.
    private func stepAutoScroll(by delta: CGFloat) {
        #if os(macOS)
        if let sv = platformScrollView, let doc = sv.documentView {
            let clip = sv.contentView
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            var origin = clip.bounds.origin
            origin.y = min(origin.y + delta, maxY)
            clip.setBoundsOrigin(origin)
            sv.reflectScrolledClipView(clip)
            if origin.y >= maxY - 0.5 { stopAutoScroll() }
            return
        }
        #else
        if let sv = platformScrollView {
            // Don't fight the user's finger.
            guard !sv.isDragging, !sv.isDecelerating else { return }
            let maxY = max(-sv.adjustedContentInset.top,
                           sv.contentSize.height - sv.bounds.height
                               + sv.adjustedContentInset.bottom)
            var offset = sv.contentOffset
            offset.y = min(offset.y + delta, maxY)
            sv.setContentOffset(offset, animated: false)
            if offset.y >= maxY - 0.5 { stopAutoScroll() }
            return
        }
        #endif
        // Fallback: accumulate distance and advance a paragraph at a time.
        fallbackAccum += delta
        guard fallbackAccum >= 120 else { return }   // ~ one paragraph height
        fallbackAccum = 0
        let cur = scrolledID ?? 0
        if cur >= paragraphs.count - 1 { stopAutoScroll(); return }
        withAnimation(.linear(duration: 1)) { scrolledID = cur + 1 }
    }

    private func stopAutoScroll() {
        autoScrolling = false
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    // MARK: - Loading & position

    private func load() async {
        loading = true
        loadError = nil
        restored = false
        let store = vm.store
        let stem = story.stem
        do {
            let body = try await Task.detached(priority: .userInitiated) {
                try store.loadBody(stem: stem)
            }.value
            paragraphs = Self.splitParagraphs(body)
            loading = false

            // Restore saved reading position.
            let fraction = current.position
            if fraction > 0.01, paragraphs.count > 1 {
                let target = min(paragraphs.count - 1,
                                 Int(fraction * Double(paragraphs.count)))
                scrolledID = target
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            restored = true
        } catch {
            loading = false
            loadError = error.localizedDescription
        }
    }

    private func savePosition() {
        guard restored, let id = scrolledID, paragraphs.count > 1 else { return }
        let fraction = Double(id) / Double(paragraphs.count)
        vm.savePosition(current, fraction: fraction)
    }

    static func splitParagraphs(_ body: String) -> [String] {
        body.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
