# CollectionManager direct collaboration contract

## Stable cloud identity

Container: `iCloud.de.holgerkrupp.CollectionManager`. Debug entitlements select
Development; Release/Production selects Production. One independently shared
collection uses its existing `collection-<collection UUID>` custom zone and root
UUID. The owner uses the private database/current-user zone owner; accepted
collections use the shared database and the actual zone owner's name from
CloudKit. Neither a database location nor a caller-provided role grants editing.
Existing share record IDs, participants and links are resolved/reused by the kit.
No automatic recovery deletes/recreates stores, zones or shares.

| Record type | Record name | Parent | Fields |
| --- | --- | --- | --- |
| Collection | collection UUID | none | name, icon, subtitle, settingsJSON, updatedAt |
| CollectionItem | item UUID | collection root | collectionID, title, brand, variant, itemDescription, state, quantity, barcodeValue/type, createdAt, updatedAt, consumedAt, tagsJSON, metadataJSON, sourceSnapshotJSON, imageSystemName, imageAsset, importSourceKey |
| CollectionEvent | event UUID | collection root | itemID, timestamp, type, note |
| CollectionItemRating | item UUID + `-rating-` + participant ID | item | id, itemID, participantID/name, value, updatedAt |
| CollectionItemComment | comment UUID | item | itemID, participantID/name, text, createdAt, updatedAt |

Settings JSON includes category, statuses, merged tags, metadata definitions,
default status and barcode-required rule. Older payloads retain safe defaults.
Image bytes are CKAssets; immutable outgoing generations retain bytes durably and
recreate only their private temporary files, never the user's original assets.
System-field archives retain server change tags when rebasing a record.

## Local transactions and state

Frozen V1 domain models remain unchanged. V2 metadata is local only and includes
transport ownership, state, locators, record system fields and outgoing snapshots.
State keys partition container, environment, opaque account and database scope;
record keys additionally include zone owner/name and record name. A changed
account cannot silently adopt the existing graph; signing back into the original
account reuses its codec/pool identity and durable journal.

The repository's atomic outbox is the incremental source (not a repeated scan of
all items). It records saves/deletes with domain writes and events. Staging captures
payloads and the exact covered mutation-generation IDs in one transaction. Only
that generation is retired on acknowledgement. Failed saves/deletes remain
journaled; viewer-blocked intent is retained without starving writable collections.
Native/foreground/push/local-save work coalesces; retries are bounded and respect
CloudKit retry-after. Background work uses the same main-app transport owner.

Independent repository and codec contexts share a per-store, per-collection
optimistic write fence. Operations capture revisions before reading; a stale or
busy commit fails and rolls back domain changes and new intent together. The
short revision lock is separate from the disk-save gate, so taking a revision
snapshot does not wait for a large background import. Metadata-only transport
saves do not invalidate domain reads. This coordinates the current process,
not separate running binaries; do not open an upgraded store in an old app.
Import-created metadata fields and web-source configuration changes are included
in their item/configuration transaction, rather than saved beforehand.

Remote records/deletes commit before engine serialization can advance. Remote
commits do not create local outbox echoes. A failed local apply/state save stops
that engine instance; restart uses unchanged durable state and replays its journal.
Record materialization failure retains the whole pending batch. The host explicitly opts into `DurableSwiftDataRecordCodec`; existing package
consumers retain their original delegate dispatch. The kit also
serializes startup/shutdown so concurrent native acceptance cannot create a
second engine pair. The Core Data backend remains unchanged.

## Merge and delete policy

Collection settings and item fields resolve as whole records by updatedAt;
ratings resolve per participant and comments per stable comment ID. Equal clocks
prefer the server. Events are append-only/idempotent by event ID. Newer local
unacknowledged intent protects the corresponding record from a fetched overwrite
or raw deletion. Save conflicts use current local values and server system fields;
a newer local delete supersedes an older in-flight save without restoring a local
zombie. Photo bytes and rebased payload are one snapshot generation. Child record
deletions remove the corresponding local row/children without echo. Loss of a root
or zone preserves local recovery data and removes edit authority; unrelated owner
collections remain intact. Real mixed-client conflict outcomes still require
signed account validation.

## Bounded handoff and manual ambiguity

Legacy manual CKServerChangeToken bytes are backed up as opaque recovery evidence,
never converted into engine serialization. A durable marker/cursor pages baseline
records; crash/restart repeats idempotently. Only proven local intent initially
becomes upload work. Targeted root import precedes engine fetch for newly accepted
shares, so child-first batches do not deadlock waiting for a later root page.
Baseline rows observed on the server reconcile against system fields; explicit
server deletions do not become automatic resurrection uploads.

A legacy row absent from the initial server view may be unsent work or a stale
copy deleted elsewhere. Its bytes remain quarantined locally. Settings provides
bounded review and an explicit upload decision for the current local value, checked
against stored authority. Unresolved candidates keep handoff incomplete. This is
not a claim that source tests prove production migration parity or safe downgrade
of an older binary against the V2 store. Preserve copies and complete the matrix
in CloudKit-RELEASE.md before rollout.

## Permission policy

Only an authoritative CKShare owner manages sharing. Editors can mutate domain
records; viewers cannot write settings, imports, items, ratings or comments.
Native participant management handles owner stop-sharing; recipients have an
explicit kit-backed Leave action. Confirmed leave/revocation suspends that shared
scope and keeps local records/pending changes read-only. Network/account failures
preserve the prior local data and do not masquerade as revoked access.

## Barcode interpretation

Scanner symbology distinguishes EAN-8 from UPC-E. UPC-E expands to GTIN-12 before
checksum validation and canonical leading-zero normalization; compressed strings
are not guessed as UPC-E when the symbology is unknown. Tests use the primary
[GS1 General Specifications §5.2.2.4](https://ref.gs1.org/standards/genspecs/24.0.0/)
zero-suppression examples. Existing canonical record values remain readable.

### Earlier private duplicates of joined collections

The joined location is canonical even when an earlier client created a private
copy with the same collection UUID. Private copy records are quarantined for
review, never applied to the joined graph, never used to grant owner access, and
never replayed to a different scope automatically. Private-copy deletions cannot
delete joined rows. Conflicting joined owners for the same root ID fail closed
without replacing the retained share locator. Those exceptional migrations need
owner review with signed accounts; all existing server data/shares stay intact.
