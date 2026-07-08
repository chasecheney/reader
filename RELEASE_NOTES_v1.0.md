# Story Reader 1.0

First release. A private library for your fiction collection — Mac and iPad,
synced through your own iCloud, and nothing else.

## Highlights

- **Self-organizing library** — titles, tags, and part numbers read straight
  from filenames; multi-part stories grouped into series in reading order,
  with manual reorder and series overrides when needed.
- **Full-text search** at 25k+ story scale: `"exact phrase"` matching and
  `AND`/`OR` operators across titles, tags, and body text.
- **Reading, done right** — serif/sans, adjustable size, light/sepia/dark
  themes, teleprompter-smooth auto-scroll (0.25×–4×), synced reading
  positions, auto mark-as-read.
- **Tagging** — filename tags plus in-app custom tags (files never renamed),
  a phrase→tag Tag Library that can auto-tag imports from story text, with
  a versioned default rule pack.
- **Spell check that learns** — corpus-derived bundled dictionary (30k+
  words, no license restrictions), per-story checking with case-preserving
  replace-all, bulk "Learn Words" across the library, synced personal
  dictionary.
- **Editing** — fix typos in place; saves recompress into the library and
  sync.
- **Library bundles (.storybundle)** — the whole library in one compressed
  file: AirDrop it, back it up, seed a fresh install, merge or replace on
  import. Bundles carry your tag rules and learned dictionary, so a shared
  library arrives speaking its own vocabulary.
- **Private by architecture** — no accounts, no servers, no analytics.
  Storage is LZFSE-compressed; sync is your personal iCloud container.

## Requirements

macOS 14+ (this DMG) · iPadOS 17+ (TestFlight, by invitation) ·
iCloud optional, used only for device sync.

## Install

Open the DMG, drag Story Reader to Applications, launch. The app is signed
with a Developer ID and notarized by Apple — Gatekeeper opens it cleanly.
Verify the download against `StoryReader-1.0.dmg.sha256` if you like.
