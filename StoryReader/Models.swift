import Foundation
import SwiftUI

/// One story file (one "part").
struct Story: Identifiable, Hashable {
    /// Stable identity: the numeric id from the filename when present,
    /// otherwise the file stem.
    let id: String
    /// Filename inside the library without the ".lzfse" suffix, e.g.
    /// "Title, Part 2 #anal #oral (12345).txt"
    let stem: String
    var title: String
    var seriesKey: String
    /// Tags parsed from the filename.
    var fileTags: [String]
    /// Tags the user added in-app (stored in synced per-story metadata).
    var customTags: [String]
    var size: Int
    var modified: Date
    var downloaded: Bool

    var favorite: Bool = false
    var isRead: Bool = false
    /// Reading position as a fraction 0…1.
    var position: Double = 0
    /// Manual position within its series (nil = automatic natural sort).
    var sortOrder: Int? = nil
    /// Manual series assignment (nil = automatic from filename).
    var seriesOverride: String? = nil

    var allTags: [String] { Array(Set(fileTags + customTags)).sorted() }
    /// The series this story actually belongs to.
    var effectiveSeriesKey: String { seriesOverride ?? seriesKey }
}

/// Related parts grouped under one series title.
struct SeriesGroup: Identifiable, Hashable {
    let id: String            // lowercased series key
    var title: String         // display title (base title of first part)
    var stories: [Story]      // natural-sorted by title

    var tags: [String] { Array(Set(stories.flatMap { $0.allTags })).sorted() }
    var favorite: Bool { stories.contains { $0.favorite } }
    var allRead: Bool { stories.allSatisfy { $0.isRead } }
    var totalSize: Int { stories.reduce(0) { $0 + $1.size } }
}

/// Per-story user metadata, stored as one small JSON file per story in the
/// iCloud container so it syncs between Mac and iPad. Last writer wins.
struct UserState: Codable, Equatable {
    var favorite: Bool = false
    var read: Bool = false
    var position: Double = 0
    var customTags: [String] = []
    /// Manual position within the story's series (nil = automatic).
    var sortOrder: Int? = nil
    /// Manual series assignment (nil = automatic from filename).
    var seriesOverride: String? = nil

    var isEmpty: Bool {
        !favorite && !read && position == 0 && customTags.isEmpty
            && sortOrder == nil && seriesOverride == nil
    }
}

enum LibraryFilter: Hashable {
    case all
    case favorites
    case unread
    case tag(String)

    var label: String {
        switch self {
        case .all: return "All Stories"
        case .favorites: return "Favorites"
        case .unread: return "Unread"
        case .tag(let t): return "#\(t)"
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var background: Color? {
        switch self {
        case .system: return nil
        case .light: return Color.white
        case .sepia: return Color(red: 0.96, green: 0.93, blue: 0.86)
        case .dark: return Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }
    var foreground: Color? {
        switch self {
        case .system: return nil
        case .light: return Color.black
        case .sepia: return Color(red: 0.24, green: 0.20, blue: 0.14)
        case .dark: return Color(red: 0.86, green: 0.86, blue: 0.87)
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .sepia: return .light
        case .dark: return .dark
        }
    }
}

extension Int {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
