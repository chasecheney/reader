# Tag Packs

The pre-populated tag rules are **data, not code** — each market SKU ships its own
`DefaultTagRules.json`, and the Swift code is identical between apps. This folder is
the source of truth:

- `EroticFiction/DefaultTagRules.json` — Story Reader's pack (a copy lives at
  `StoryReader/DefaultTagRules.json`, which is what actually gets bundled).
- `Production/DefaultTagRules.json` — Story Navigator's pack (television, film,
  live production vocabulary). Copy it into the Navigator target's folder as
  `DefaultTagRules.json` when wiring that SKU.

## Format

```json
{
  "packVersion": 1,
  "name": "Erotic Fiction",
  "rules": [
    { "phrase": "glory hole", "tag": "gloryhole" },
    { "phrase": "navy !blue|blazer|suit|tie", "tag": "military" }
  ]
}
```

- Matching is whole-word and case-insensitive; word variants are separate rules.
- A phrase may carry a "not followed by" exclusion after ` !` (see the navy rule).
- Several phrases may share one tag.

## Releasing a pack update

1. Edit the pack here, copy it over the target's `DefaultTagRules.json`,
   and **bump `packVersion`**.
2. Ship the app update. On first launch after the update, new rules are merged
   **additively**: anything the user edited stays edited, anything they deleted
   stays deleted (seed bookkeeping lives in `TagPackState.json` in the iCloud
   container). Users see "N new default tag rules added from the <name> pack."
3. Mid-cycle, packs can also travel in `.storybundle` files: exports include the
   sender's tag rules, and imports merge them additively — so a production's
   coordinator (or a library curator) can distribute vocabulary without an app
   release.

## Two-SKU wiring (when splitting Story Navigator onto this codebase)

Duplicate the app target in Xcode; give the new target its own bundle id, name,
icon, and `DefaultTagRules.json` (from `Production/`). Everything else — parser,
reader, search, bundles, spell check — is shared source.
