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

The default rules ship as a **versioned data pack** (`StoryReader/DefaultTagRules.json`; source of truth and the Production pack for Story Navigator live in `Packs/` — see `Packs/README.md`). Seeded on first launch; when an app update carries a newer `packVersion`, new rules merge additively — your edits stay edited, your deletions stay deleted. Edit or delete freely — a cleared library stays cleared — and "Restore Defaults" re-adds missing defaults without touching your own rules. Exported `.storybundle` files carry your tag rules too, and imports merge them additively, so a curator or production can distribute vocabulary without an app release.

When you import files, an options step appears: filename tags are always picked up, and a checkbox offers "search story text and add tags from the Tag Library." With it checked, each imported story's text is scanned (case-insensitive, whole-word matching) and matched tags are saved as custom tags — they sync, they show in the sidebar tag list and filters, and files are never renamed. Tags already present in the filename aren't duplicated. The checkbox state is remembered between imports.

## Editing and spell check

Reading Options menu → **Edit Story…** switches the reader to a plain-text editor. Save (⌘S) compresses the edited text back into the library, re-indexes it, and syncs to the other device; Cancel discards. While editing, **Check Spelling** lists every word not found in the dictionary — with occurrence counts, one-tap "replace all" suggestions (case-preserving), and "Add to Dictionary" for names and slang. The personal dictionary syncs between devices (`UserDictionary.txt` in the iCloud container).

The import options include "Collect unknown words for spelling review" (on by default, adds only a few percent to import time since the text is already in memory): after the import finishes, the Learn Words review opens pre-populated with every unknown word the new files contained, so a big import ends with one approval pass instead of a separate library scan.

Sidebar → **Learn Words…** is the bulk version: it scans the whole library, aggregates every unknown word by how many stories it appears in, and lets you approve batches into the personal dictionary ("Select All Shown" with a minimum-stories filter). Words in many stories are almost always real — recurring character names, slang; one-story words are usually typos and best left unchecked. The scan is cancellable and takes a few minutes for a 25k library.

The bundled dictionary (`StoryReader/dictionary.txt`, ~30k words) is **derived from the story corpus itself** — document-frequency filtered with a typo guard — so it ships with the app and inside shared builds with **no third-party license restrictions**, and it already knows the corpus's contractions, slang, and recurring names. The list is ordered most-common-first; suggestion ranking uses that order (that's why "teh" suggests "the"). Rebuild it any time with `scripts/make_dictionary.py CORPUS_DIR StoryReader/dictionary.txt`.

## Library bundles (share, back up, restore)

The toolbar's shipping-box menu packages the entire library into a single compressed `.storybundle` file, and merges such files back in.

- **Export Library Bundle…** writes one file containing every downloaded story, already LZFSE-compressed (export never recompresses — it streams the library's own blobs, so even a 25k-story library exports fast). Stories still waiting on iCloud download are counted and reported, never silently dropped.
- **Import Library Bundle…** asks Merge or Replace. **Merge** (default): stories you don't have are added, stories where the bundle is newer are updated, everything else is skipped; nothing is ever removed, and re-importing is harmless. **Replace**: removes all existing stories first so the library ends up exactly matching the bundle — favorites, positions, custom tags, and your dictionary are kept, and re-apply to stories that return with the same id.
- **After export** you can Share directly (AirDrop, Messages, Mail — on both platforms) or Save to File. On iOS both import and save go through the Files picker, so Dropbox, iCloud Drive, and On My iPad all work; a bundle received by AirDrop lands in Files and imports from there. On the Mac it's an ordinary file you can share any way you like.

Bundles also carry the exporter's **personal spelling dictionary** (learned names and slang): importing merges those words into the recipient's dictionary — never removing anything — so a shared library arrives with its vocabulary already known. Reading state (favorites, positions) still stays out; the local search index is never shared either, since each device rebuilds it automatically. Old bundles without a dictionary and old app versions reading new bundles both work unchanged.

That gives you all four workflows in one mechanism: share the library with another user (AirDrop / copy the file — they import it into their own library), seed a fresh install in one step instead of re-importing thousands of `.txt` files, keep a compact offline backup, and ship updates by exporting a new bundle after adding stories — recipients import it and only the new stories are written.

Format (for reference): `"STRYBNDL"` magic, format version, JSON manifest (stem, offset, size, mtime per story), then the LZFSE blobs back-to-back. See `LibraryBundle.swift`.

## Notes

- Custom tags added in-app live in the synced metadata, not the filename — files are never renamed.
- Search matches word prefixes across title, tags, and full text, and supports query syntax: `"quoted text"` requires the exact phrase (words adjacent, in order); `AND` / `OR` (any case) combine terms, with AND binding tighter than OR; bare words are implicitly ANDed. Example: `blue AND gold OR "my brother"`. Note: the index uses porter stemming, so an exact phrase matches word forms — `"my brother"` also matches "my brothers". Changing that means a different FTS tokenizer and a full re-index. Filter by tag from the sidebar; counts include custom tags.
- A story is auto-marked read when you scroll past ~92%.
- Cmd-R (Mac) or the refresh button re-scans the library at any time.
