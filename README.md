# Story Reader

A macOS + iPad reading app for libraries of tagged text files.

What it does: imports `.txt` files named `"{Title} #tag1 #tag2 (id).txt"`, stores them LZFSE-compressed (typically 60–70% smaller) in a shared iCloud library, groups related parts ("…, Part 1/2/3", "Chapter Two", roman numerals, etc.) into a single story, indexes everything into a local SQLite full-text index for instant search over titles, tags, and body text, and lets you tag files individually in-app. Favorites, read status, reading position, and custom tags sync between devices.

## Requirements

Xcode 16 or later. macOS 14+ / iPadOS 17+ to run. iCloud sync requires a paid Apple Developer account (Apple doesn't grant the iCloud entitlement to free accounts). Without it, the app still works — each device just keeps its own local library.

## Setup (one time)

1. Open `StoryReader.xcodeproj` in Xcode.
2. Select the StoryReader target → Signing & Capabilities → choose your Team. Change the bundle identifier if you like (the iCloud container id follows it automatically).
3. Xcode should create the iCloud container automatically on first signed build. If it complains, press "Try Again" in Signing & Capabilities after a few seconds.
4. Build & run: pick "My Mac" as the destination for the Mac app, or your iPad for the iPad app. Both come from this single target.
5. No iCloud / free account? Delete the three iCloud entries from `StoryReader/StoryReader.entitlements` and build — the app falls back to local storage.

## First import

On the Mac, click **+** in the sidebar and select a folder of .txt files (or individual files). The app compresses each file into its library and then builds the search index — large libraries (tens of thousands of files) take a few minutes on first index; progress shows in the sidebar. After that, iCloud uploads in the background and the iPad downloads and indexes on its own (its sidebar shows "Waiting for iCloud to download…" until files arrive; press Refresh to re-scan).

## How it stores things

- Library: `iCloud container/Documents/Stories/*.txt.lzfse` (compressed originals; filenames unchanged, so tags and ids stay in the name).
- Per-story metadata: `…/Documents/UserData/<id>.json` — favorite, read, position, custom tags. Small per-story files sync cleanly with last-writer-wins.
- Search index: local on each device (`Application Support/StoryReader/index.sqlite`, SQLite FTS5). Never synced, rebuilt incrementally from the library, safe to delete.

## Tag Library (auto-tagging on import)

Sidebar → **Tag Library…** opens the rule editor: each rule maps a word or phrase to a tag, e.g. "marine" → `#military`, "glory hole" → `#gloryhole`. Several phrases can share one tag. Rules are stored in the iCloud container, so both devices use the same library.

The app ships with a default rule set (~40 rules covering #bond, #rape, #gangbang, #gloryhole, #humil, #incest, #orgy, #prison, #slave, #military, #uniform, #police, and #war), seeded on first launch. Edit or delete them freely — a cleared library stays cleared — and the editor's "Restore Defaults" button re-adds any missing default rule without touching your own.

When you import files, an options step appears: filename tags are always picked up, and a checkbox offers "search story text and add tags from the Tag Library." With it checked, each imported story's text is scanned (case-insensitive, whole-word matching) and matched tags are saved as custom tags — they sync, they show in the sidebar tag list and filters, and files are never renamed. Tags already present in the filename aren't duplicated. The checkbox state is remembered between imports.

## Library bundles (share, back up, restore)

The toolbar's shipping-box menu packages the entire library into a single compressed `.storybundle` file, and merges such files back in.

- **Export Library Bundle…** writes one file containing every downloaded story, already LZFSE-compressed (export never recompresses — it streams the library's own blobs, so even a 25k-story library exports fast). Stories still waiting on iCloud download are counted and reported, never silently dropped.
- **Import Library Bundle…** merges a bundle into the library: stories you don't have are added, stories where the bundle is newer are updated, everything else is skipped. Re-importing the same bundle is harmless (idempotent). User metadata — favorites, positions, custom tags — is never included in or touched by bundles; a bundle carries content, not someone's reading state.

That gives you all four workflows in one mechanism: share the library with another user (AirDrop / copy the file — they import it into their own library), seed a fresh install in one step instead of re-importing thousands of `.txt` files, keep a compact offline backup, and ship updates by exporting a new bundle after adding stories — recipients import it and only the new stories are written.

Format (for reference): `"STRYBNDL"` magic, format version, JSON manifest (stem, offset, size, mtime per story), then the LZFSE blobs back-to-back. See `LibraryBundle.swift`.

## Notes

- Custom tags added in-app live in the synced metadata, not the filename — files are never renamed.
- Search matches word prefixes across title, tags, and full text, and supports query syntax: `"quoted text"` requires the exact phrase (words adjacent, in order); `AND` / `OR` (any case) combine terms, with AND binding tighter than OR; bare words are implicitly ANDed. Example: `blue AND gold OR "my brother"`. Filter by tag from the sidebar; counts include custom tags.
- A story is auto-marked read when you scroll past ~92%.
- Cmd-R (Mac) or the refresh button re-scans the library at any time.
