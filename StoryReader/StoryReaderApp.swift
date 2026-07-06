import SwiftUI

@main
struct StoryReaderApp: App {
    @StateObject private var vm = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .task { await vm.start() }
        }
        // ⌘R lives on the Refresh toolbar button in ContentView.
    }
}
