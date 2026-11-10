# Architecture

A short tour of how the app is put together and why.

## Overview

```
 Evernote export (Yarle)        Other Markdown exports
 Markdown + _resources/         Markdown + images
          \                        /
           \   .catalogue.json    /      <- written with an AI assistant,
            v   sidecars         v          checked by a validator
        ┌───────────────────────────────┐
        │        Mac app (SwiftUI)      │  import, browse, search, edit, cook
        │  ┌─────────────────────────┐  │
        │  │       RecipeCore        │  │  shared Swift library
        │  │  Core Data store + files│  │
        │  └─────────────────────────┘  │
        └───────────────┬───────────────┘
                        │  local network sync (Bonjour, no server)
        ┌───────────────┴───────────────┐
        │   iPhone / iPad app (SwiftUI) │  browse, search, cook, record activity
        │       RecipeCore (same)       │
        └───────────────────────────────┘
```

## Shared core

`RecipeCore` compiles for both macOS 13 and iOS 15. Platform differences are kept behind `#if os(macOS)` / `#if os(iOS)`, and newer APIs are gated with `if #available`.

**Persistence.** Core Data with a queryable model (recipes, blocks, categories, tags, ingredients, cook history). SwiftData was ruled out because it needs iOS 17. The schema is versioned; each upgrade first backs up the SQLite file family into `MigrationBackups`, migrates into a separate new store, verifies it, and only then switches over. Each migration has a test.

**Files.** Imported images and PDFs are copied into `Assets/<recipe id>/<sha256>.<ext>` and referenced by relative path. Content-addressed names make repeat imports idempotent and let the backup verify every file by hash. Thumbnails are generated off the main thread into a bounded cache.

**Import.** `MarkdownImporter` parses front matter, headings, bullets, numbered steps, wiki-style and ordinary image embeds and PDF attachments into typed blocks, keeping the complete original Markdown alongside. Every resource path is resolved and confined to the chosen import folder, so a crafted link cannot read files outside it. Exact duplicates are recognised by a fingerprint of text plus image hashes; near duplicates go to a review screen rather than being merged automatically.

**Catalogue.** Categories and tags come from fixed JSON lists bundled with the app (`Resources/`). A child category implies its group (a Korean recipe also appears under Asian). Sidecars are validated on import: unknown ids are dropped, confidence must be between 0 and 1, and the sidecar must name the file it sits beside.

**Search.** A small query language (`#tag`, `category:`, `cuisine:`, `cooked:never`, `cooked:>6m`, quoted phrases, `-exclusions`) over a precomputed search document per recipe. Ingredient synonyms map American and alternative names to one canonical British name. Search is cached and debounced in the UI.

## Sync

The Mac owns recipe content; the phone holds a mirror. Three activity fields (favourite, cooked dates, view count) can change on either side and merge both ways:

- **Favourite:** the later change wins, and a side that never changed it does not override one that did.
- **Cooked log:** union of both logs by entry id; a deletion (tombstone) wins.
- **Views:** each side sends only the views since the last sync, which are added, so nothing is counted twice.

`SyncEngine` is a pure function from (local state, peer snapshot) to changes, so the merge rules are unit-tested without a network. `NetworkSync` carries the messages over an `NWConnection` found by Bonjour on the local network, with a pairing code check and length-prefixed framing. There is no server and no cloud account. Wrapping the connection in TLS with a key derived from the pairing code is a planned hardening step.

## Testing

`swift test` runs 80 tests, all against temporary libraries, covering import edge cases (encodings, path traversal, odd filenames, adjacent images), migrations, duplicate detection, search, backup and restore with tamper detection, and the sync merge rules. `Scripts/check-ios.sh` compiles and links the shared code and iPhone app for iOS 15.
