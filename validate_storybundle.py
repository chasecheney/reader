#!/usr/bin/env python3
"""
validate_storybundle.py — conformance checker for the .storybundle format.

  python3 validate_storybundle.py FILE.storybundle [--list]

Checks everything STORYBUNDLE_SPEC.md requires of a writer: magic, version,
manifest well-formedness, required fields, entry bounds/overlaps, stem
safety, blob prefixes, and optional-field shapes. Exit code 0 = conformant.
No dependencies beyond the Python standard library.
"""
import json
import struct
import sys

MAGIC = b"STRYBNDL"
SUPPORTED_VERSION = 1

def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)

def warn(msg):
    print(f"warn: {msg}")

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__.strip())
    path = sys.argv[1]
    listing = "--list" in sys.argv

    data = open(path, "rb").read()
    if len(data) < 20:
        fail("file shorter than the 20-byte header")
    if data[:8] != MAGIC:
        fail(f"bad magic {data[:8]!r} (expected {MAGIC!r})")
    version = struct.unpack("<I", data[8:12])[0]
    if version != SUPPORTED_VERSION:
        fail(f"formatVersion {version} (this checker supports {SUPPORTED_VERSION})")
    mlen = struct.unpack("<Q", data[12:20])[0]
    if mlen == 0 or 20 + mlen > len(data):
        fail(f"manifestLength {mlen} exceeds file size {len(data)}")

    try:
        manifest = json.loads(data[20:20 + mlen].decode("utf-8"))
    except Exception as e:
        fail(f"manifest is not valid UTF-8 JSON: {e}")

    for req in ("formatVersion", "created", "generator", "storyCount", "entries"):
        if req not in manifest:
            fail(f"manifest missing required field '{req}'")
    entries = manifest["entries"]
    if manifest["storyCount"] != len(entries):
        fail(f"storyCount {manifest['storyCount']} != entries length {len(entries)}")

    blob_start = 20 + mlen
    blob_len = len(data) - blob_start
    seen_stems = set()
    spans = []
    for i, e in enumerate(entries):
        for req in ("stem", "offset", "size", "mtime"):
            if req not in e:
                fail(f"entry {i} missing '{req}'")
        stem, off, size = e["stem"], e["offset"], e["size"]
        # stem safety (spec section 8)
        if "/" in stem or "\\" in stem or "\x00" in stem:
            fail(f"entry {i} stem contains a path separator or NUL: {stem!r}")
        if stem.startswith(".") or ".." in stem.split("/"):
            fail(f"entry {i} stem unsafe: {stem!r}")
        if len(stem.encode("utf-8")) > 255:
            fail(f"entry {i} stem exceeds 255 bytes")
        if stem in seen_stems:
            fail(f"duplicate stem: {stem!r}")
        seen_stems.add(stem)
        # bounds
        if off + size > blob_len:
            fail(f"entry {i} blob [{off},{off+size}) outside blob region ({blob_len} bytes)")
        spans.append((off, off + size, stem))
        # blob prefix
        blob = data[blob_start + off: blob_start + off + size]
        if size >= 3 and blob[:3] != b"bvx":
            warn(f"entry {i} blob does not start with LZFSE 'bvx' prefix "
                 f"({blob[:4]!r}) — real bundles must carry LZFSE frames")
        if listing:
            print(f"  {stem}  ({size} B compressed, mtime {e['mtime']})")

    # overlap check
    spans.sort()
    for (a0, a1, sa), (b0, b1, sb) in zip(spans, spans[1:]):
        if b0 < a1:
            fail(f"blobs overlap: {sa!r} and {sb!r}")
    covered = sum(a1 - a0 for a0, a1, _ in spans)
    if covered < blob_len:
        warn(f"{blob_len - covered} unreferenced bytes in the blob region")

    # optional fields
    ud = manifest.get("userDictionary")
    if ud is not None:
        if not (isinstance(ud, list) and all(isinstance(w, str) for w in ud)):
            fail("userDictionary must be an array of strings")
    tr = manifest.get("tagRules")
    if tr is not None:
        for j, r in enumerate(tr):
            if not (isinstance(r, dict) and isinstance(r.get("phrase"), str)
                    and isinstance(r.get("tag"), str) and r["phrase"] and r["tag"]):
                fail(f"tagRules[{j}] must be {{phrase: string, tag: string}}")
            if "#" in r["tag"] or " " in r["tag"]:
                warn(f"tagRules[{j}] tag {r['tag']!r} not normalized (no '#', no spaces)")

    print(f"OK: {path}")
    print(f"    version {version} · {len(entries)} stories · "
          f"{len(ud or [])} dictionary words · {len(tr or [])} tag rules · "
          f"{len(data)} bytes total")

if __name__ == "__main__":
    main()
