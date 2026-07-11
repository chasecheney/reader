# The `.storybundle` Format — Specification

**Version 1 · July 2026 · Status: stable**

A `.storybundle` is a single-file, compressed, shareable library of plain-text
stories plus the vocabulary that organizes them (tag rules and a spelling
word list). It is designed for offline exchange — AirDrop, download, USB —
with **idempotent, additive merging** on import: importing the same bundle
twice changes nothing, and importing a newer bundle adds or updates only what
changed.

Reference implementations: Story Reader and Story Navigator
(`StoryReader/LibraryBundle.swift` in this repository).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be
interpreted as described in RFC 2119.

---

## 1. Design goals

1. **One file** — no directories, no zip container, trivially transferable.
2. **No recompression** — blobs are stored in the same compressed form the
   reference library uses on disk, so export/import stream bytes.
3. **Random access** — the manifest carries byte offsets, so a reader can
   extract one story without touching the rest.
4. **Merge-friendly** — enough metadata (`mtime`, `size`) to decide
   add/update/skip per story without content diffing.
5. **Forward compatible** — unknown manifest keys are ignored; new optional
   fields never break old readers.

## 2. File identification

| Property            | Value                                            |
|---------------------|--------------------------------------------------|
| Extension           | `.storybundle`                                   |
| Magic (first 8 B)   | ASCII `STRYBNDL`                                 |
| UTI (Apple)         | `com.cheney.storyreader.storybundle`, conforms to `public.data` |
| Media type          | `application/vnd.cheney.storybundle` (vendor tree per RFC 6838 §3.2; see §11 for the registration template. The legacy `x-` prefix is deliberately not used — RFC 6838 §3.4 deprecates it and such types can never be registered.) |

Third-party apps on Apple platforms MAY import (declare the UTI) but SHOULD
NOT export a *different* type under the same identifier.

## 3. Binary layout

All integers are **little-endian**. There is no padding or alignment.

| Offset | Size      | Field                                    |
|-------:|-----------|------------------------------------------|
| 0      | 8         | Magic: `53 54 52 59 42 4E 44 4C` ("STRYBNDL") |
| 8      | 4         | `formatVersion` — UInt32, currently `1`  |
| 12     | 8         | `manifestLength` — UInt64, byte length of the manifest JSON |
| 20     | manifestLength | Manifest — UTF-8 JSON, no BOM        |
| 20 + manifestLength | rest of file | Blob region: story blobs back-to-back, in manifest `offset` order |

Blob positions are `blobRegionStart + entry.offset` where
`blobRegionStart = 20 + manifestLength`.

Readers MUST reject files whose magic differs, whose `formatVersion` is
greater than the highest version they implement, or whose declared lengths
exceed the file size. Readers SHOULD apply a sanity cap on `manifestLength`
(the reference uses 500 MB).

## 4. Manifest schema

A single JSON object. Writers MUST emit all **required** fields; readers
MUST ignore unknown fields (this is the extension mechanism).

```json
{
  "formatVersion": 1,
  "created": "2026-07-08T12:00:00Z",
  "generator": "Story Reader",
  "storyCount": 1,
  "entries": [
    {
      "stem": "Example Story #demo (1).txt",
      "offset": 0,
      "size": 12,
      "mtime": 1751976000.0
    }
  ],
  "userDictionary": ["kyneston"],
  "tagRules": [ { "phrase": "table read", "tag": "rehearsal" } ]
}
```

| Field           | Req. | Type    | Meaning |
|-----------------|------|---------|---------|
| `formatVersion` | yes  | int     | Mirrors the header version (informational; the binary header is authoritative). |
| `created`       | yes  | string  | ISO 8601 UTC timestamp of export. |
| `generator`     | yes  | string  | Human-readable producer name/version. |
| `storyCount`    | yes  | int     | MUST equal `entries.length`. |
| `entries`       | yes  | array   | One per story; see below. |
| `userDictionary`| no   | [string]| Exporter's learned spelling words, lowercase, straight apostrophes allowed. |
| `tagRules`      | no   | array   | Exporter's phrase→tag rules; see §7. |

### 4.1 Entry fields

| Field    | Type   | Meaning |
|----------|--------|---------|
| `stem`   | string | The story's filename **without** any compression suffix, e.g. `"Title, Part 2 #anal #oral (12345).txt"`. Unique within the bundle. See §6 for the naming convention and §8 for security rules. |
| `offset` | uint   | Byte offset of this story's blob **relative to the start of the blob region**. |
| `size`   | uint   | Compressed blob length in bytes. Blobs MAY be stored in any order but MUST NOT overlap. |
| `mtime`  | double | Source file modification time, seconds since 1970-01-01 UTC. Drives update decisions (§5). |

## 5. Blobs and merge semantics

Each blob is **one story's complete text, LZFSE-compressed**. LZFSE is
Apple's open-source LZ+FSE codec (reference implementation:
github.com/lzfse/lzfse); frames begin with ASCII `bvx` (e.g. `bvx2`, `bvx-`,
`bvx$`). Decompressed text SHOULD be UTF-8; readers SHOULD fall back to
Latin-1 for legacy content.

Readers SHOULD verify the 3-byte `bvx` prefix before accepting a blob and
MUST bound decompression (reject or truncate absurd expansion; the corpus
norm is ~2.5–3×).

**Merge algorithm** (normative for importers that maintain a library):

For each entry, compare with any local story of the same `stem`:

1. **Absent locally** → add.
2. **Present, same compressed `size`** → skip (assumed identical).
3. **Present, different `size`, bundle `mtime` newer than local** → update
   (overwrite).
4. **Otherwise** → skip (local is newer).

This makes imports idempotent and lets a newer bundle ship deltas by simply
containing everything — only changes are written. A "replace" import mode
(clear local stories first) MAY be offered but MUST be explicit user intent.

Importers MUST NOT modify blobs, and MUST NOT write anything back into the
bundle file.

## 6. Stem naming convention (informative but strongly recommended)

```
{Title} #tag1 #tag2 … (id).txt
e.g.  The Cable Guy, Part 2 #anal #oral (12345).txt
```

- **Tags**: `#` + `\w+`, lowercase preferred, between title and id.
- **id**: decimal digits in parentheses at the end; the stable story
  identity for user metadata. When absent, the full stem serves as id.
- **Series grouping**: readers that group multi-part works derive a series
  key by stripping trailing part/chapter markers ("Part 2", "Chapter IV",
  "Book Three", trailing "- 3", etc.) and lowercasing. The reference
  algorithm is `FilenameParser.swift` (a verified port of `scriv_build.py`);
  implementations MAY differ but SHOULD treat roman and spelled numbers as
  digits before stripping.

Bundles whose stems don't follow the convention are still valid — they just
import as untagged, ungrouped stories titled by stem.

## 7. Tag rules

Each rule is `{ "phrase": string, "tag": string }`.

- **Tag**: lowercase, no `#`, no whitespace (readers normalize).
- **Matching**: case-insensitive, **whole-word** (`\b`-bounded); a phrase may
  contain spaces (words must be adjacent in order) or hyphens (literal).
- **Exclusion syntax**: a phrase may carry a "not followed by" clause after
  the two characters ` !` (space, bang):
  `"navy !blue|blazer|suit|tie"` matches the word *navy* except when the next
  word (separated by whitespace or hyphens) is one of the listed
  alternatives. Equivalent regex:
  `\bnavy\b(?![\s\-]+(?:blue|blazer|suit|tie)\b)`.
- **Merge**: additive only, keyed by `lowercase(phrase) + "→" + tag`;
  importers MUST NOT delete or alter existing local rules.

`userDictionary` merges the same way: set union, never removal.

## 8. Security considerations

- **Path traversal**: stems become filenames. Importers MUST reject or
  sanitize stems containing `/`, `\`, NUL, a leading `.`, or `..` path
  segments, and SHOULD cap stem length at 255 UTF-8 bytes.
- **Bounds**: every `offset + size` MUST lie within the blob region; readers
  MUST validate before reading.
- **Decompression bombs**: bound output size (§5).
- **Duplicate stems**: writers MUST NOT emit them; readers encountering them
  SHOULD keep the first and ignore the rest.
- Bundles carry no executable content and no user reading state (favorites,
  positions) by design — a bundle is content plus vocabulary, not identity.

## 9. Versioning and extension policy

- **Add an optional manifest field** → no version change. Old readers ignore
  it (JSON decoders MUST tolerate unknown keys); new readers treat its
  absence as "not present".
- **Change the binary layout, blob codec, or the meaning of an existing
  field** → increment the header `formatVersion`. Readers MUST refuse
  versions above what they support with a clear message.
- Version 1 fields defined optional so far: `userDictionary` (spelling
  words), `tagRules` (phrase→tag rules). Both shipped after 1.0 bundles
  existed — proof the extension path works.

## 10. Test vector

A minimal valid bundle (304 bytes). Header, byte-exact:

```
offset 0:  53 54 52 59 42 4e 44 4c  01 00 00 00 10 01 00 00   STRYBNDL........
offset 16: 00 00 00 00                                        ....
           └ magic ──────────────┘  └version┘ └manifestLength = 0x110 = 272┘
```

Manifest (272 bytes, keys sorted, compact separators):

```json
{"created":"2026-07-08T12:00:00Z","entries":[{"mtime":1751976000.0,"offset":0,"size":12,"stem":"Example Story #demo (1).txt"}],"formatVersion":1,"generator":"Story Reader","storyCount":1,"tagRules":[{"phrase":"table read","tag":"rehearsal"}],"userDictionary":["kyneston"]}
```

Followed by one 12-byte blob at file offset 292. (In this vector the blob is
the placeholder `bvx-FAKE.end` to keep the dump printable; a real bundle
carries a genuine LZFSE frame there. JSON key order and whitespace are not
significant — this exact serialization merely makes the vector reproducible.)

A conforming reader MUST: accept the file, report one story with stem
`Example Story #demo (1).txt`, size 12, mtime 1751976000; expose the
dictionary word and the tag rule; and reject the file if any of magic,
version, or bounds were altered.

## 11. Media type registration template (RFC 6838 §5.6)

Ready to submit at iana.org/form/media-types when registration is desired.

```
Type name:                 application
Subtype name:              vnd.cheney.storybundle
Required parameters:       none
Optional parameters:       none
Encoding considerations:   binary
Security considerations:   See STORYBUNDLE_SPEC.md section 8. The format
                           carries compressed plain text plus JSON metadata;
                           no executable content. Known risks for consumers:
                           path traversal via entry stems, out-of-bounds
                           offsets, and decompression expansion; conforming
                           readers validate all three. The manifest may
                           contain personal vocabulary (spelling words, tag
                           phrases) — a privacy consideration when sharing.
Interoperability considerations:
                           Blobs are LZFSE-compressed (open-source codec:
                           github.com/lzfse/lzfse). Unknown manifest keys
                           must be ignored; the binary header version gates
                           incompatible changes.
Published specification:   STORYBUNDLE_SPEC.md, distributed with the
                           reference implementation
                           (github.com/chasecheney/reader)
Applications that use this media type:
                           Story Reader, Story Navigator (macOS/iPadOS)
Fragment identifier considerations:
                           none
Additional information:
  Deprecated alias names:  none
  Magic number(s):         first 8 bytes ASCII "STRYBNDL"
                           (53 54 52 59 42 4E 44 4C)
  File extension(s):       .storybundle
  Macintosh file type code(s): none; Apple UTI
                           com.cheney.storyreader.storybundle
Person & email address to contact for further information:
                           <fill in before submission>
Intended usage:            COMMON
Restrictions on usage:     none
Author:                    ChaseCheney LLC
Change controller:         ChaseCheney LLC
```

## 12. Reference implementation pointers

- Writer/reader: `StoryReader/LibraryBundle.swift`
- Filename convention & series grouping: `StoryReader/FilenameParser.swift`
- Tag rule matching (incl. exclusion syntax): `StoryReader/TagLibrary.swift`
- LZFSE: `NSData.compressed(using: .lzfse)` on Apple platforms;
  github.com/lzfse/lzfse elsewhere.

*This specification may be implemented freely, without restriction. If you
ship a compatible implementation, please keep the semantics above —
especially additive merging and the security rules — so users' bundles stay
interchangeable.*
