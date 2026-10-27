# CollectionManager 1.0 validation — 27 October 2026

This file records actual evidence and limitations; it is not release approval.
Xcode 27.1 (27A9275), Swift 6.4, arm64 MacBook Pro M4 Pro/24 GiB, macOS 27.2.

## Baseline

Fresh remote clones at CollectionManager `5bf59645f4fe851b8516ecc0af5e57b122b7e771`
and kit `860b0f3d5950a9129056c2056a00e21cb08827b0`: unsigned macOS/iOS Release
builds passed, original three macOS tests passed, kit warnings-as-errors passed.
MealPlan remote reference `c1285b95dc29d83479045e0bdd02421e474e000b` was read
from a separate clone. Its local pre-existing project/catalog edits were untouched.

## Implemented and verified locally

- Foundation `9956a5a`: 34 focused tests passed (measurement method excluded).
- Latest integrated macOS suite: 81 tests passed, zero failures, including full
  1k/10k/50k host measurements, typed failures/atomic writes, real POSIX unreadable
  store preservation, audited V1→V2 fixture/export opening, edit sessions,
  provider errors, settings/defaults, multi-zone/scope/account isolation,
  restart handoff, pending-delete/generation/conflict/asset tests and queries.
- Kit `239da36` fixes durable apply/state failure progress. `5e9a09d` additionally
  coalesces concurrent startup/shutdown; 20 tests passed with warnings as errors.
  Core Data source/API behavior was preserved.
- Intermediate integrated unsigned iOS Release build passed. Development-signed
  Production archives built for iOS and macOS; embedded entitlements contained
  the intended container and Production environment. This is not App Store
  distribution/export validation. Final archive rechecks follow integration.
- iPhone Duo iOS27.1 simulator: 77 unit tests passed in the earlier integrated
  run and both UI smoke tests passed. Mac UI execution was blocked by Developer
  Tools authorization; the target compiles. No Mac UI runtime pass is claimed.

Final clean-clone evidence is appended after the tested integration is committed.

## Measured host performance

See PERFORMANCE.md for exact samples and scope. In matching unoptimized Debug
runs, 50k synthetic SQLite seed time fell from 151,425 ms to 4,398 ms after
rejecting impossible date-tag shapes before allocating formatters. 10k fell
from 30,789 ms to 818 ms. Optimized test-build indexed search was about 95 ms at
50k, versus 107 ms assembling text per query. Search/filter/sort now execute on
background tasks with cancellation/generation checks. Image-heavy host snapshots at 50k JPEG-backed records measured about 1161 MiB
resident and 620 MiB physical footprint after fetch; 128 thumbnails used 18 MiB decoded
pixels. These are sampled values, not peak bounds. UI frames, physical-device
latency/memory and network-scale counts remain unmeasured.

## Required external evidence

1. Revoke/rotate the previously public Games EAN credential at the provider;
   verify the old value no longer authorizes requests, without posting the value.
2. Supply an authorized Xcode 27.1 CI host (the hosted macos-26 image currently
   lists only 26.x); run the actual workflow. No self-hosted runner was registered.
3. Enable Developer Tools access for the execution app or run UI tests from an
   authorized Xcode/test host. Repeat all smoke, resize, large-text, VoiceOver,
   keyboard, contrast, long-string and RTL tests on iPhone/iPad/Mac.
4. Deploy/review Production CloudKit schema and execute the signed owner/editor/
   viewer matrix with real independent Apple Accounts, existing/new shares,
   offline edits, revoke/leave/stop, reinstall and interrupted handoff. Review
   ambiguous legacy candidates explicitly; no automatic resurrection is allowed.
5. Verify provider retention, privacy policy and App Store disclosures, then
   validate distribution-signed archives and supported physical devices.

Issues #10, #16 and #17 remain open until their actual release gates pass.
