# Historical engineering note: file lifecycle and recovery

Status: deprecated development snapshot; this is **not** the current personal-version
product contract or acceptance evidence.

The material below describes a broader pre-personal-milestone implementation and its
open system questions. It is retained for engineering traceability only. In particular,
references to automatic saves, size tiers, a full Recovery Center, safe-copy Markdown
links, Compare/Save Copy conflict actions, or a "release" do not describe the current
user-visible product. Use [current-implementation.md](current-implementation.md),
[architecture.md](architecture.md), and the approved product documents under
`../../文档/01-产品设计/06-版本规划/` for the active scope and UAT.

Nothing below may be cited as proof that the personal-version manual-save and close
flows have passed real-process validation.

## Ownership

| Concern | Owner in the current build | Contract |
| --- | --- | --- |
| Window, `fileURL`, change count, Save, Save As, Save Copy, revert | AppKit's `NSDocument` behind `DocumentGroup` | All user-facing lifecycle operations call the native document API. Inflow does not write the current Markdown path as a second lifecycle writer. |
| Bytes requested for one save | `SaveEnvelope` | Immutable nonce, document revision, bytes, SHA-256, source URL, target URL, target expectation and operation. A completion acknowledges only the exact envelope whose bytes are observed at the target. |
| External-change comparison | `DocumentFileSafetySession` | Tracks the last observed committed bytes separately from current editor bytes. A newer edit made while an older envelope is saving remains uncommitted. |
| Product-visible byte recovery | encrypted `DocumentRecoveryStore` | This is the only recovery source read or offered by Inflow's Recovery Center. It never writes the user's Markdown path. |
| Native framework recovery internals | AppKit | Inflow does not consume or merge native recovery bytes. Whether `FileDocument` can completely suppress every private AppKit recovery artifact is not established by a public API and remains an open system-prototype item below. |

## Save and Save As

1. The editor freezes a `SaveEnvelope` from the current encoded document and captures the target expectation (`absent` or an exact resource snapshot). An existing target is opened once with `O_NOFOLLOW`; device/inode/generation, birth/ctime/mtime, size and regular-file type are checked with `fstat` before and after a streaming read, while content is bound by SHA-256. The snapshot never performs `lstat` followed by a second pathname read.
2. `MarkdownDocument.fileWrapper` asks the shared write guard for the prepared envelope's bytes before constructing the real `FileWrapper`, then rechecks the target expectation at the serialization boundary. If the SwiftUI document value acquired a newer edit after `prepareSave`, that edit is not substituted into the in-flight wrapper and remains dirty after the older envelope commits.
3. The native `NSDocument.save(to:ofType:for:)` operation remains the only outer save entry point.
4. Completion rereads the target through the same single-descriptor snapshot primitive and commits only when its bytes equal the envelope. A successful Save or Save As adopts `SaveEnvelope.bytes` as the Recovery committed base and immediately refreshes the current recovery head; it never substitutes the editor's then-current text. A mismatch is not reported as success: the current edit remains available and the target must be re-inspected before the user compares or saves a copy. The implementation does not infer that the target still contains its prior bytes.
5. Save As supports either callback order: the scene may publish the new `fileURL` before or after native completion. The guard retains a target-scoped candidate baseline until both events converge.
6. Save Copy validates its target and never changes the source document's committed baseline or URL.

An untitled document's first Save command uses this same Save As flow; it does not bypass the envelope through the default responder-chain Save command. If the new `fileURL` appears while the user has already edited beyond the frozen envelope, the candidate baseline remains the envelope bytes and the newer edit remains uncommitted.

The release conflict actions are **Compare**, **Save Copy** and **Reload**. Overwriting an externally changed file and recreating a deleted file are not exposed in the release UI because `FileDocument` does not provide a public hook that lets this code conditionally own AppKit's final replacement.

The single-descriptor snapshot closes the check/read split for each observation; it does not make that observation and AppKit's later private pathname replacement one atomic operation. That residual boundary remains an explicit system-prototype item below.

## Reload

Reload is a single native lifecycle operation surrounded by one versioned decision:

1. `prepareReload` verifies the selected disk snapshot and freezes its bytes.
2. `NSDocument.revert(toContentsOf:ofType:)` updates AppKit's lifecycle and change-count owner.
3. `commitReload` verifies the same bytes again, adopts one committed base, updates the SwiftUI value and clears source-editor undo.

The pre/post checks detect cooperative changes but cannot prove which pathname bytes AppKit read inside its private revert implementation. This residual race is covered by the open prototype item below; the implementation does not claim an atomic conditional revert.

## Recovery format and handoff

- Schema version 2 records `lineageID`, epoch, revision, recovery content hash, last committed content hash and transfer IDs.
- A disk hash equal to the committed hash proves that the recovery head is the later local revision. A hash equal to neither is classified as diverged/unknown; no ordering is invented.
- Restoration is `claim -> new durable head -> consume old head`. Claiming first writes the old head with its target ID and updated retention timestamp. A second crash before the first target flush therefore still leaves the old bytes recoverable.
- The target head is written and read back with matching lineage, epoch and source claim before the source is removed.
- Startup/load reconciles an authenticated transfer pair before presenting records. If a crash happened after the target became durable but before source deletion, the valid newer target suppresses the claimed source immediately and cleanup is retried idempotently, so one lineage is not exposed with two active heads.
- Each live editor session has a monotonically increasing in-memory generation. Normal-close removal is asynchronous but generation-gated; reopening/reactivating the same record ID cancels stale close work, and any removal already in flight is followed by an immediate flush of the newer generation.
- Recovery Center always opens a recovered value as a document; it never overwrites the original path. Saved disk bytes make a matching recovery head redundant.

The full record—including body, path, bookmark, selection and window state—is AES-GCM encrypted. Production Release builds store a 256-bit `AfterFirstUnlockThisDeviceOnly` key in Keychain. Xcode Debug builds are intentionally isolated because their ad-hoc designated requirement changes on rebuild: they use a separate `DevelopmentRecovery` root and a random mode-`0600` file key inside that root. XCTest uses a unique temporary root and a fixed test-only key, so tests never read or mutate production recovery data or request access to `com.inflow.desktop.recovery`. The authenticated header binds format version, record ID, plaintext length and key identifier. Recovery files are mode `0600`; directories are `0700`; both are excluded from backup. A file is fsynced before rename and the parent directory is fsynced after rename.

Limits are 64 MiB plaintext JSON per head and 512 MiB encrypted storage overall. The encrypted-file limit is independent: it covers base64, fixed envelope fields and the worst-case slash escaping accepted from older envelopes, while new writes disable slash escaping. A valid maximum plaintext record is therefore not quarantined merely for serialization overhead. Active heads expire after 30 days; quarantined material expires after 7 days. Before rejecting a head at the total quota, reclamation removes incomplete temporary files, expired quarantine, expired or disk-redundant records, and then the oldest superseded record for a lineage that already has a newer durable head. The newest durable head of every lineage is never a quota victim. If that ordered cleanup cannot make room, recovery enters its visible degraded state while native Markdown saving remains available. A missing key quarantines old ciphertext and creates a new domain key.

Recovery Center's doubly confirmed “Clear all recovery content” action removes encrypted heads, legacy records, quarantine, temporary material and the domain key without reading, deleting or modifying any Markdown file. It also cancels live periodic recovery tasks and suppresses their cleared content identity; selection, scroll or view-only updates cannot recreate the deleted head. A later body or encoded-file-property change starts a fresh protected head.

Legacy plaintext schema-1 records are validated, migrated once to encrypted schema 2, and then removed. Invalid legacy bytes are encrypted before quarantine and the plaintext source is removed; if encrypted quarantine cannot be written, the unusable plaintext is deleted instead of being retained raw. Invalid encrypted records are isolated and never opened automatically. Every quarantine item receives its isolation timestamp, and the seven-day retention window starts at that timestamp rather than the source file's former modification date.

## Local links

- Markdown targets inside the active project are opened with `O_NOFOLLOW`, checked against the selected project identity and current snapshot, and kept bound to the original project path. A fragment is percent-decoded once, normalized to NFC and carried into the destination surface for exact generated-ID matching.
- Project-local PNG/JPEG/PDF targets are read and revalidated before a read-only managed copy is opened. Explicitly clicked targets outside the active project—including Markdown, text, images, PDF and other regular files—are handed directly to Launch Services; Inflow does not require permission to pre-read or copy their bytes.
- Local and remote Markdown image references are rendered in both split preview and instant editing. Instant editing reserves TextKit layout space and overlays a mouse-transparent image while preserving every source character and the plain-text undo history.
- Relative paths, absolute paths and `file://` URLs share the same planner. A target outside the active project is not granted project-editing trust, but it is no longer rejected solely for crossing the project root.

## Identity, recent records, settings and durability

- Ordinary file opens are classified before UTF-8 decode: at most 1 MiB is full-featured, more than 1 MiB through 10 MiB is source-only, and more than 10 MiB is rejected. Source-only mode keeps the complete text, find, save, encrypted recovery and conflict protection while suppressing preview, outline, full highlighting, diagnostics, statistics and structural formatting. The rejection error explains that the file can be located in Finder and handled with another tool; the public `FileDocument` error presentation cannot provide a proven custom Finder button, so no such button is claimed.
- Existing regular files expose a device/inode identity helper and recent records deduplicate matching identities before canonical-path fallback. The current `DocumentGroup` open path still delegates ownership to `NSDocumentController`, which only reports `wasAlreadyOpen` for the URL it recognizes; no application-wide active identity registry has proved that two different hard-link paths cannot produce two editable sessions. The release guarantees session reuse only for the same canonical path; hard-link alias deduplication remains `OPEN`.
- Recent-document capacity is a physical persistence limit. Lowering it trims paths and bookmarks immediately; increasing it cannot reveal previously retained hidden records.
- Settings keys are listed in the versioned `AppPreferences.Registry`; type changes and renames require an explicit migration before its schema version advances.
- Strict crash durability is claimed only for the encrypted recovery replace described above. Native document saves, ordinary recent/settings writes and exports retain the guarantees of their public framework APIs; no parent-directory-fsync guarantee is claimed for them.

## Open system prototype items

Items 1–3 are blockers for approving a formal 1.0 candidate. The current component evidence supports development-preview validation only; it must not be translated into a release-pass claim.

1. A real-process test must establish the precise `FileDocument`/AppKit ordering among wrapper generation, coordinated safe replacement, completion, `fileURL` publication and change-count updates under Save As and a concurrent external writer.
2. If a product requirement needs an atomic compare-and-replace at the final pathname boundary, migrate that lifecycle to a custom `NSDocument` transaction and test metadata, presenter, change-count and failure recovery. Until then, the release must retain the non-overwriting conflict actions above.
3. A real crash/relaunch harness must verify Keychain-locked startup, sudden termination between every claim/transfer fsync boundary and the framework's native recovery behavior. Component tests validate the current store state machine but are not a substitute for this system evidence.
4. A real two-path open test and application-wide active document registry are required before claiming that hard-link aliases always converge on one editable owner. The existing device/inode helper and recent-list deduplication do not prove active-window ownership.
