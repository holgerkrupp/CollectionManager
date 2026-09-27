# Collection Manager on iPhone Duo

Analysis date: 2026-09-14. This plan applies Apple’s iPhone Duo guidance to the current SwiftUI collection-management app.

Revision 2026-09-14 (second pass): re-read the published HIG page and added layout options per surface, control ownership, bar-free scanner surfaces, an explicit open/close transition contract, and the conditional reserved regions. Nothing from the first pass was removed.

Revision 2026-09-19: added implementation details from Apple’s new preparation technology overview, including container-specific bar behavior, toolbar APIs, arrangement-hosting cautions, camera direction, and pose-by-pose validation.

## Recommendation in one sentence

Keep the existing adaptive split navigation, use the inner display for collection + item context instead of simply widening the table, and separate layout transitions from draft persistence so folding can never commit or discard edits.

## Device and platform baseline

| Surface | Hardware size | Pixels | Early @3x layout target | Size-class guidance |
| --- | --- | --- | --- | --- |
| Outer display | 5.4-inch | 1398 × 2034 | about 466 × 678 pt | Compact-width iPhone experience |
| Inner display | 7.6-inch | 1878 × 2670 | about 626 × 890 pt or 890 × 626 pt when rotated | Regular width and regular height |

The point sizes are derived planning targets, not Apple-published viewport values. Always use live scene geometry, safe areas, layout margins, and reserved regions. Vertical bars, camera cutouts, the active fold, and Split View can make the usable area smaller and asymmetric.

The project currently targets iOS 26. Build with the iOS 27.1 SDK for full inner-display behavior and guard `ArrangementView`, reserved-region APIs, toolbar visibility priorities, and other 27.1 additions with availability checks.

## Apple rules that matter here

- Model the outer and inner displays as compact and regular forms of the same scene.
- Preserve functionality, selection, navigation, filters, and unfinished work when the active display changes.
- Do not hard-code layouts for hinge angles. Let size classes and adaptive containers establish structure; use hinge state for effects or interaction only.
- A partially folded inner display exposes an active division reserved region. Indivisible controls, rows, cards, text, and images must avoid it.
- `NavigationSplitView`, lists, tables, sheets, forms, alerts, menus, and system bars provide the best automatic adaptation.
- `ArrangementView` is appropriate for a stable two-content relationship. Keep the app’s navigation outside it.
- Prefer even grid columns across fold-spanning content.
- The outer display and inner landscape can place toolbars and tab bars vertically. Use standard placement, grouping, priorities, and overflow.
- In tabletop pose, favor view-only content above and frequent interaction below.

## Current code assessment

### What already adapts well

- `RootView` uses `NavigationSplitView` unconditionally. It can collapse on the outer display and expand on the inner display without swapping the entire navigation model.
- `selectedCollectionID` remains in the same root hierarchy, which is a good basis for selection continuity.
- `CollectionDetailView` already offers compact cards and a regular-width table.
- Search, filter, sort, layout choice, add/edit sheets, menus, and most controls use standard SwiftUI components.
- Forms and scanner flows are modal tasks that can adapt independently of the collection browser.

### Risks to fix before calling the app Duo-ready

1. The regular table’s edit path calls `commitAll()` from `onDisappear`. Folding to compact can remove the table view, so a layout transition may save drafts even though the user never chose Save.
2. Regular width alone is not proof that the table has enough uninterrupted width. In book pose, the fold can cut through cells or separate a field value from its header.
3. Card statistics use a fixed three-item `HStack`. A centered item or label can intersect the active division region.
4. The filter bar is horizontally scrollable, while the table and editing bar contain fixed or dense controls. Continuous content may cross the fold, but individual interactive controls may not end underneath it.
5. Item detail currently arrives primarily through sheets. The inner display can preserve list context more effectively with a detail column or inspector.
6. The layout picker is a custom segmented control with a fixed width inside a trailing toolbar group. It needs a side-bar-compatible representation and lower priority than Add.

## Layout by device state

| State | Recommended shell | Collection Manager presentation |
| --- | --- | --- |
| Closed, outer portrait | Collapsed `NavigationSplitView` | Collection list, then a one-column card list. Use full-screen or sheet add/edit/scanner flows with persistent drafts. |
| Closed, outer landscape | Compact hierarchy with vertical toolbar | Keep the active collection and filters. Prioritize Add; allow layout, sort, and secondary commands to overflow. |
| Fully open, inner portrait | Expanded split navigation | Collections on the leading side and cards or table in detail. Show selected item detail in an inspector when space permits. |
| Fully open, inner landscape | Two- or three-context workspace with vertical bars | Collection navigation + item results + selected item detail. Use the table only when the proposed uninterrupted region is wide enough. |
| Partially folded, book pose | Region-aligned browser/detail | Collection or item list on one side and selected item detail on the other. Confine a table to one region or use an intentional fold gutter. |
| Partially folded, tabletop pose | Reference above, controls below | Put photo, barcode result, or selected-item summary above; place metadata fields, scanner confirmation, and save/cancel below. |
| Split View | Naturally collapsed or narrowed split view | Re-evaluate cards versus table from the container proposal. Never assume an open device means the app owns all inner pixels. |

These are adaptive outcomes, not distinct layouts selected by exact hinge angle.

## Layout options per surface

The state table says what should happen. These are the containers that can produce it, so each choice is deliberate rather than a consequence of the single `horizontalSizeClass` gate.

### Browsing

| Option | Container | When it is right | Cost |
| --- | --- | --- | --- |
| N1 — two columns | `RootView`’s `NavigationSplitView`: collections, then items. Item detail pushes inside the items column. | The safe inner-display default, and the one extra level of hierarchy the HIG describes with its Mail example. | Detail replaces the results while reading. |
| N2 — two columns plus inspector | Collections and items, with the selected item’s metadata, photo, and history in an inspector | The best fit for this app. Collection management is comparison work: the inspector keeps the results in place, and it collapses cleanly when a fold shrinks a region. | One more piece of state to preserve across a fold. |
| N3 — three columns | Collections, items, item detail | Flat inner landscape only, once measurement confirms the middle column can still show an identifying field. | Two collapse points, and a middle column that degrades first. |

Recommended: N2. It is the layout that turns the inner display into something better than a wider phone, and it avoids the third column that a fold will squeeze first.

### Item representation

| Option | When it is right | Fold rule |
| --- | --- | --- |
| I1 — cards | The default whenever a usable region cannot present table columns at accessible widths. | A card keeps its image, name, key identifier, and disclosure affordance in one usable region. |
| I2 — table | An uninterrupted flat region wide enough for the columns that matter. | In a book pose, confine the table to one region or split it at a semantic boundary. Never let the hinge fall through arbitrary columns, separating a value from its header. |
| I3 — gallery grid | Photo-led collections. | Prefer an even column count when the grid spans both regions, as the HIG asks, so content divides cleanly. |

The current gate is regular size class alone. Base the choice on the container’s proposal after safe-area and division insets instead: regular width is not proof of an uninterrupted region.

### Add, edit, and scan

| Option | Container | When it is right |
| --- | --- | --- |
| F1 — split arrangement | Primary: captured photo, barcode result, or matched item. Secondary: the editable metadata form. | The inner display. Side by side in a book pose, capture-above-form in a tabletop pose, with no pose detection. |
| F2 — form only, preview inline | The outer display and narrow widths. | Keep the current modal flow as the compact form. |
| F3 — full-width, bar-free scanner | While the scanner is live. | The HIG allows a full-width layout for visual interfaces that do not scroll, and a camera preview is one. Keep every overlay inside the safe area and clear of the Dynamic Island and the status bar. |

Tabletop scanning is the pose this app benefits from most: the device stands itself up, the camera reads the item, and both hands stay free to hold the object being catalogued.

### Settings

`CollectionSettingsWindow` has its own `NavigationSplitView`. Two split views in one scene will both try to adapt to the same fold. Present it as a sheet or a separate scene rather than nesting it inside the main split view’s detail column, and let the system place the sheet away from the fold.

## Concrete changes

### 1. Make fold transitions non-transactional

Remove draft persistence from view-lifecycle events that can be caused by responsive layout. In particular, `onDisappear { commitAll() }` must not be the table editor’s save contract.

Use an explicit edit session instead:

- keep the table’s draft values in a scene-level or model-owned edit session;
- expose Save/Done and Cancel/Revert deliberately;
- autosave only if it is the app’s documented global editing model, and debounce changes independently of view disappearance;
- preserve the session when the table becomes cards or the item moves into an inspector;
- ask before abandoning a dirty session only when the user actually leaves its semantic scope.

A fold, rotation, Split View resize, camera interruption, or compact/regular switch must not save, delete, or discard collection data.

### 2. Evolve the split view into list + detail context

Keep `RootView` and its `NavigationSplitView`. On the inner display, add a selected-item route that can appear as a detail column or inspector while the collection results remain visible. This is more valuable than stretching every row.

Suggested hierarchy:

1. collection sidebar;
2. filtered/sorted item results in cards or a table;
3. selected item’s metadata, photo, barcode, history, and edit commands.

On the outer display, collapse the same hierarchy to collection → results → item. Store collection and item selection above any presentation decision so opening and closing retains both.

### 3. Choose cards versus table from usable region width

The current `horizontalSizeClass == .regular` gate is too broad. Base the choice on the actual container proposal after safe-area and division-region insets:

- cards are the default when a usable region cannot present columns at accessible widths;
- the table can fill an uninterrupted flat inner canvas;
- in book pose, constrain the table to one side or split it at a semantic boundary—never through arbitrary columns;
- if horizontal scrolling is necessary, keep the identity/photo/name column and edit affordance understandable while other fields scroll;
- preserve search, filters, sorting, selection, scroll position where practical, and drafts when representation changes.

Do not use `UIScreen.main`, the device idiom, or raw display resolution to choose the representation.

### 4. Make cards, statistics, and filters fold-safe

Replace the fixed three-statistic row with an adaptive one-, two-, or four-cell grid. Prefer an even count across a fold-spanning container and preserve a legible minimum width. With large Dynamic Type, use a single vertical stack rather than shrinking labels.

The horizontally scrolling filter strip is continuous content, so it need not displace wholesale. Ensure each chip/control can scroll completely clear of the fold, and prevent resting or snapping a selected filter underneath the active division region. Apply the same rule to the editing bar’s Add Field control and its fixed-width field picker.

Cards should keep their image, primary name, key identifier, and disclosure/action affordance in one usable region. A decorative image can extend to an occlusion boundary; meaningful text and controls cannot.

### 5. Use add, edit, and scanning flows as fold-aware arrangements

The metadata form and its preview/scanner result form a durable content pair suitable for `ArrangementView` on iOS 27.1:

- flat/wide: preview or captured image beside form fields;
- portrait/tall: preview above fields;
- book pose: preview/detail on one side, editable fields on the other;
- tabletop: captured photo/barcode/item match above, confirmation fields and Save/Cancel below.

Keep the modal/navigation container outside the arrangement. Persist all form fields and captured results above it so pose changes do not restart VisionKit, dismiss confirmation, or clear input.

When the camera is active on the inner display, `CameraCaptureAccessory` could optionally show a lightweight barcode/photo result or capture confirmation on the outer display. This is an enhancement, not a replacement for the complete in-app flow.

### 6. Prepare commands for vertical bars

For the outer display and inner landscape:

- make Add the prominent, high-priority action;
- express cards/table choice with a standard menu or toolbar-friendly symbol and title; do not depend on the fixed 120-point segmented control fitting horizontally;
- group filter/sort/layout actions and let low-frequency commands enter system overflow;
- keep selection/edit commands near the results or item they affect;
- avoid embedding several unrelated buttons in a single custom toolbar item;
- confirm leading/trailing placement follows the physical device side correctly in right-to-left locales.

### 7. Respect reserved regions directly

Consume scene/window-provided safe and reserved regions rather than estimating a hinge rectangle. Use:

- active division frames to form a gutter or decide whether two regions can host the current minimum widths;
- occlusion frames for edge-to-edge imagery, live scanner previews, and camera-active layouts;
- normal safe areas and margins for all other chrome.

An inactive division region should have no layout cost. Use hinge-change callbacks only for optional animations, focus behavior, or scanner effects—not for structural layout selection.

### 8. Keep each control with the content it affects

The HIG asks that controls belonging to a content area other than the trailing one stay with that area, using Mail’s list controls as its example. Collection Manager’s controls have clear owners once two panes are visible:

- Results-owned: the search field, the filter strip, sort, and the cards-versus-table choice. These act on the item list, so they belong above the items pane and not in the trailing vertical bar, where they would read as belonging to the selected item. `.searchable` in `CollectionDetailView` is bound to `store.searchText`, which is the right ownership model — the query lives above the view and survives a shell change. Keep it that way and apply the same pattern to filter and sort.
- Collection-owned: create, rename, and delete a collection; collection-level import and export.
- Item-owned: edit, duplicate, move, attach a photo, rescan, and delete.

### 9. Reduce text-only bar buttons, and rethink the layout picker

Labels that include text stay in a horizontal bar; only symbols move to the vertical axis.

- The layout picker is a custom segmented control with a fixed 120-point width inside a trailing toolbar group. A fixed-width horizontal segmented control has no sensible vertical representation. Replace it with a menu whose items carry symbols and titles, and give it lower visibility priority than Add.
- Give every item both a symbol and a title with `Label`. The title is used in the overflow menu even when the bar shows only a symbol.
- Make Add the prominent action, placed after Back or Close at the top of the vertical axis, which is the standard placement order.
- Use `ToolbarItemGroup` instead of manual spacing, and avoid putting unrelated buttons into one custom toolbar item.
- Move any app-owned ellipsis menu into the system overflow menu, and reserve the ellipsis for overflow only.
- Do not override the default placement to force a horizontal bar back.

## The open and close transition

The state table describes configurations. This section describes the event between them, which for this app is where the data-loss risk lives.

### Promotion and demotion

| Outer display (compact) | Inner display (regular) | Rule on transition |
| --- | --- | --- |
| Collection list, nothing selected | Sidebar with the same collection selected, items in detail | Selection by collection ID, never by index. |
| Collection with an item pushed | That item selected in the results, detail or inspector showing it | The push becomes the selection, and the results scroll to keep the item visible. Closing re-pushes the same item. |
| Cards with an active search and filters | The same query, filters, and sort | These already live in the store; confirm nothing re-derives them from the view. |
| Table with cells being edited | Cards with the same draft values, or the table if the region supports it | The edit session survives the representation change. Nothing commits, reverts, or duplicates. |
| Scanner or add sheet presented | The same flow, repositioned away from the fold | Captured images, recognised barcodes, matched candidates, and typed fields survive. |

### What may move and what may not

- May change: cards versus table, grid column counts, the number of visible navigation columns, the bar axis, whether the item detail is a column, an inspector, or a push.
- May not change: the selected collection or item, the search query, filters, sort, the results position, any draft value, or which field has focus.
- Preserve results position by item ID rather than by content offset, because switching between cards and table changes every row height.

### The rule that matters most

A fold, a rotation, a Split View resize, or a compact-to-regular switch must never be transactional. The table editor’s `onDisappear { commitAll() }` is the canonical example: on this device, responsive layout causes disappearance, so that line turns folding the phone into a save the user never asked for. It is worth searching the whole project for the same pattern — saves, deletions, uploads, or cache invalidation triggered by view lifecycle rather than by an explicit action.

### Interactions that are in flight when the device moves

- A table cell being edited. Focus survives only if the cell’s identity is stable; the value must be held in the edit session rather than in the field.
- An active scanner. A pose change must not restart VisionKit, drop a recognised barcode, or dismiss a duplicate-match confirmation. Folding into tabletop mid-scan is the expected behaviour.
- A horizontally scrolling filter strip mid-scroll. Continuous content may cross the fold while scrolling, but a chip must never come to rest under the active folding region. Check the resting position after a fling, not only after a controlled drag.
- Photo picking and import from a neighbouring app in Split View: a drop that lands while the scene resizes must resolve exactly once.

## Reserved regions that come and go

Three of the four regions are conditional, so a correct layout can become wrong with no navigation at all.

| Region | When present | What Collection Manager must do |
| --- | --- | --- |
| Outer front-facing camera | Always, on the outer display | Never pin custom chrome to the top of the vertical axis; the system arranges bar items around it. |
| Dynamic Island expansion | While a Live Activity is running | No ActivityKit target today. A long import or bulk scan is a plausible candidate; if one is added, the top of the outer display’s vertical axis grows, so lay out from the live safe area rather than a fixed inset. |
| Inner front-facing camera | Only while the camera is active | This is the important one here. On the inner display the camera is hidden until `ScannerViews` activates it, and then the UI moves aside. Place the reticle, result chip, and confirmation controls from live reserved regions, because the region arrives after the view has laid out. |
| Folding region | Only while partially open | Zero-width when flat. Use the active frame as a real gutter, and to decide whether a table still has an uninterrupted region wide enough for its columns. |

## Implementation order

1. Build with Xcode 27.1 and record Device Hub baselines for root navigation, cards, table, editing, and scanning.
2. Replace table `onDisappear` commits with a persistent, explicit edit-session contract.
3. Hoist item selection, filters, layout preference, drafts, and scanner/form state above adaptive branches.
4. Add inner item detail/inspector context while keeping `NavigationSplitView` as the shell.
5. Make cards/table selection depend on usable region width and add fold-safe grid/gutter behavior.
6. Convert form + preview/scanner result to an arrangement and audit vertical toolbar priorities.

## Verification matrix

- Snapshot planning sizes: 466 × 678, 678 × 466, 626 × 890, and 890 × 626 points. Use Device Hub for authoritative safe and reserved regions.
- Fold/unfold with a selected collection and item, active search/filter/sort, scrolled results, and open inspector. Confirm context remains stable.
- Start editing multiple table cells, then fold, rotate, resize Split View, or switch to cards. Confirm nothing commits, reverts, duplicates, or loses focus unexpectedly.
- Book pose: verify cards/table, collection list, item detail, filters, and editing bar do not place indivisible content over the fold.
- Tabletop pose: capture/scan an item, edit its metadata below, and change pose before saving. Confirm the camera/result/form state survives.
- Test no-photo and long-photo items, long field names/values, many custom fields, empty collections, large datasets, and duplicate barcode matches.
- Test VoiceOver, keyboard navigation, Bold Text, largest accessibility sizes, localization, and right-to-left layout.
- Verify delete confirmations, import/export, scanner permissions/errors, sheet detents, and cancellation in every display state.

### Additional checks from the second pass

- Edit several table cells, then fold, rotate, resize Split View, and switch to cards. Nothing commits, reverts, duplicates, or loses focus.
- Grep the project for saves, deletes, or uploads triggered by view lifecycle rather than by an explicit action, and confirm a resize cannot trigger any of them.
- Start the scanner on the inner display and confirm the reticle and result chip move aside as the inner camera region appears.
- Fold from flat into tabletop mid-scan. The session continues and no item is recorded twice.
- Fling the filter strip and fold. No chip comes to rest under the active folding region.
- In a book pose, confirm the table either stays inside one region or splits at a semantic boundary, never through a column.
- Open an item on the outer display, unfold, and confirm the results scroll that item into view rather than resetting to the top.
- Confirm the layout picker has a vertical-axis representation and sits below Add in visibility priority.
- Verify the settings split view is presented as a sheet or separate scene, and that two split views never compete for the same fold.

## Technology-overview refinements (2026-09-19)

Apple’s new overview specifies bar behavior by container. In the expanded collection `NavigationSplitView`, sidebar/content bars remain horizontal while the detail bar can be vertical; inspector bars remain horizontal. Add/edit and scanner sheets default to vertical bars on the outer display. On the inner display, centered/leading sheets use horizontal bars, whereas trailing sheets use vertical ones. Test the actual detent and placement; use `presentationPlacement(_:)` or `toolbarVerticalBehavior(_:)` only when the chosen form layout calls for it. A custom scanner or item header can read `toolbarVerticalEdge` rather than inferring bar orientation from size.

Replace the fixed-width custom layout picker in the toolbar with an icon-and-title menu or action. Apple states that custom-view and title-only toolbar items do not appear vertically. Keep Add visible with `visibilityPriority(_:)`; use `axisBehavior(_:)` for inclusion, `ToolbarOverflowMenu` for sort/layout/export, `.cancellationAction` for Close, and `.topBarPinnedTrailing` for prominent Save/Done. A full-bleed item photo or scanner preview may use `backgroundExtensionEffect()` beneath a vertical bar, while the reticle, result chip, and confirmation controls remain within safe and reserved areas.

The overview warns that an `ArrangementView` inside a navigation split view, `List`, or `ScrollView` can make one child inaccessible. For preview + metadata, place the arrangement at the add/edit content root, with the `Form` as a child rather than as a parent; if the surrounding sheet or split-detail host clips a pane, keep a regular adaptive form and handle the fold via reserved regions. Split style puts preview and form side by side in wide space or top/bottom in tall space. For any AVFoundation/AVKit-backed photo scanner, choose the camera by facing direction and re-evaluate when opening, closing, or rotating; the active camera may then point the other way. Verify live scanner, permissions, barcode result, edit sheet, and popovers in every rotated pose, with unsaved drafts intact.

## Sources

- [Preparing your app for iPhone Duo — Technology Overview](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
- [Designing for iPhone Duo — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [iPhone Duo technical specifications](https://www.apple.com/iphone-duo/specs/)
- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/)
- [Leverage multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/)
