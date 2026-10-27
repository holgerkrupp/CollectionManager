# CollectionManager 1.0 work map

GitHub is authoritative: [release hub #16](https://github.com/holgerkrupp/CollectionManager/issues/16)
and [collaboration epic #17](https://github.com/holgerkrupp/CollectionManager/issues/17).
Do not recreate their detailed checklists here.

Implemented source and deterministic coverage now include persistent recovery,
typed/atomic repository writes, immutable V1 + additive V2 migration fixtures,
Keychain-only Games EAN credentials, settings validation, parent-owned edit
sessions, package-based SwiftData collaboration/native UI, durable journal and
handoff, background queries, bounded image thumbnails and host benchmarks.
See README and docs/VALIDATION.md for precise evidence and limitations.

Remaining gates are tracked in #6–#17 as appropriate: provider credential revocation (#6); signed existing/new share,
role/revoke/leave/offline/mixed-client/production schema matrix (#9/#10/#17);
UI runtime authorization and compatible CI host (#11); measured device/frame/image
memory/network scale acceptance (#12); device accessibility/RTL/long-string,
provider retention and App Store disclosures (#13); final distribution archives
and supported devices (#14). Resolve any ambiguous legacy candidates explicitly.

Documentation must follow final code and evidence (#15). No release hub/epic
closure until its real gates pass. Optional iPhone Duo/post-1.0 ideas remain in
duo.md; full JSON backup/import, more templates, AI enrichment and expanded
history presentation are not 1.0 prerequisites.
