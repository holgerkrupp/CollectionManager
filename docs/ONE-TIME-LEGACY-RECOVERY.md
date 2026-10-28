# One-time recovery for the unpublished installation

The pre-5bf59645 app used SwiftData's implicit `Application Support/default.store`.
Startup later selected `Application Support/CollectionManager/CollectionManager.store`
without importing the former. This recovery is an explicit launch operation for
that unpublished installation, not a new end-user recovery/settings workflow.

Use the **Production** scheme. Preserve an external copy of the entire app's
Application Support and preferences before updating the existing installation.
Do not uninstall, overwrite either database, clear tokens or reset CloudKit.

Launch once with `--recover-legacy-default-store-once`. The app:

- Saves the original SQLite database, real WAL/SHM and external-data folders.
- Opens/upgrades only a working copy. The old sync-state model predates frozen
  V1 by three fields; that copy uses inferred additive lightweight migration.
- Saves a second snapshot of the current store while holding its write gate.
- Imports missing domain records with their original UUIDs and raw payloads;
  existing current values, authority and queued tombstones take precedence.
- Retains both queues, legacy tokens, current locators, shares and engine state.
- Commits the import and a local-only receipt atomically. Repeat launches return
  that receipt rather than duplicate or reimport records.
- Rewinds only the bounded legacy bootstrap cursor for reconciliation, leaving
  opaque engine state intact. Existing quarantined baselines are not duplicated.
- Leaves cloud sharing/sync and scheduled web updates paused after recovery.

After checking the restored library, launch once with
`--resume-after-legacy-recovery-review` to acknowledge recovery and resume normal
sync. Previously queued edits/deletions can then be sent; other recovered rows
enter the existing conservative handoff/reconciliation. Remove either argument
from subsequent normal launches. The receipt remains durable across restarts.

The one-time command can be supplied with Xcode Run arguments or devicectl:

```sh
xcrun devicectl device process launch --device DEVICE --terminate-existing \
  de.holgerkrupp.CollectionManager -- --recover-legacy-default-store-once
```

Verification on 28 October 2026: 155 macOS unit tests passed with Swift warnings
as errors, including the explicit private-backup test. The signed iOS Production
build passed and its Production entitlement/signature were verified. The private
trial preserved every legacy field of items, events, queued changes, web sources
and sync-state rows, and kept current collection values/transport ownership/zone
records unchanged. Failure injection rolls back receipt, data and queue together;
restart/retry, existing viewer authority and pending-delete cases are covered.
No private database, account IDs or collection names are committed to Git.

The optional real-data test is enabled only by setting
`TEST_RUNNER_CM_RECOVERY_BACKUP` to a private backup folder before xcodebuild.
It skips on CI when that input is absent. Synthetic cases always run.
