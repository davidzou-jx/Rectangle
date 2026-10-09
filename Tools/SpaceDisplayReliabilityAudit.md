# Space and display reliability audit

October 9, 2026. Baseline: `cf4f6e6`, including the pending Space-switch latency work described in [SpaceSwitchLatencyResearch.md](SpaceSwitchLatencyResearch.md).

This audit covers the added Space/display commands and the shared placement,
snapping, animation, and multi-window paths inherited from the base app.

| Feature/path | Reliability changes and checks |
| --- | --- |
| Relative switch-only commands | Preserve bounded per-display intent, exact destinations, normal-desktop direct switching, verified full-screen gesture fallback, and native quiet-period protection. Reordered or incomplete topology cancels the burst. |
| Numbered desktop switching | Validate the complete managed topology before resolving any ordinal. Leaving a full-screen Space uses gesture steps. Direct completion requires time-separated visibility samples; unrelated input or topology changes prevent rollback. |
| Adjacent window moves, with follow | Use direct transfer and activation together when available, including normal desktops separated by a full-screen Space. Keep the gesture commit callback for systems without direct activation, and reject targets it cannot reach in one gesture. Revalidate window identity, source membership, display ownership, and eligibility before committing. |
| Adjacent window moves, without follow | Verify membership and background stacking order without activating the application. Stop ordering retries when the source/destination display changes Space or the user supplies input. |
| Numbered window moves, with/without follow | Apply the same ownership, identity, order, and cancellation rules across both displays. Position the window only after destination membership arrives. Keep the separate numbered follow preference. |
| Failed or interrupted bridged moves | Recovery covers adjacent and numbered moves. Restore source membership/display only while Rectangle owns them. An interrupted submitted request drains under the existing lease with read-only checks and a bounded timeout, without focus/frame changes. |
| Legacy drag fallback | Require a visible ordinary window, exact source/destination IDs, and destination membership. Notifications trigger a check rather than prove completion. Polling handles missing notifications. Refuse full-screen intermediaries that a single native drag cannot safely cross. Recheck acquisition and AX hit targets before posting the gesture. |
| Private API availability | Check Objective-C selector encodings, nil initializers, positive IDs, fresh topology, and normal window-move destinations before submission. Retain the established normal window level; ordering uses AX raises. |
| Focus Next Display | Resolve from the active window, reject drag/Mission Control/owned operations, skip unusable AX candidates, and recheck visibility/display availability before activation. Empty, single-display, and offscreen cases do nothing. |
| Display ordering/detection | Use deterministic ordering for vertical/staggered layouts. Replace the non-transitive overlap comparator with rows that share vertical overlap. Handle no screens and invalid geometry; unmatched windows get actual neighbors of the ordered fallback. |
| Next/previous/specific display moves | Do not replay a previous display move as a center action. Keep specific-display auto-maximize behavior consistent with next/previous. Clamp proportional sizes to the destination before clamping position. |
| Restore after unplugging a display | Validate saved geometry and bring a completely offscreen saved frame into the current display's usable area. Guard delayed restore fallback against a changed display/session/Space operation. |
| Delayed placement and frame animations | Cancel delayed cross-display retries on Space/display/session/sleep changes and verify the destination is still connected with the expected frame. Frame animations also cancel on session deactivation. Existing interruption and size-constraint tests remain in the full suite. |
| Native drag snapping and previews | Clear drag identity, snap area, and pending released-size restoration on Space/display/sleep/session changes. Close previews immediately during transition cleanup. Synthetic Space-move events remain excluded from snapping. |
| Tile All, rows/columns, cascade, reverse-all | Reuse fresh visible-window evidence for selection, including the existing conservative one-to-one AX/CG matching for ID-less windows. Exclude other Spaces, invalid geometry, fullscreen/modal windows, and Todo. Avoid unsafe minimum-size conversion and empty active-app layouts. |
| Work area, Dock, Stage Manager, Todo, combined displays | Preserve corrected Dock/combined-area behavior and existing reservation tests. Ignore reservations that leave a nonfinite or empty usable frame, including the secondary-display early-return path. |
| Shortcut/menu/URL routing | Route Space commands before ordinary frame/multi-window actions; the latter cannot overlap a held Space operation. Preserve command identities, desktop numbering, independent follow preferences, and shortcut-cycle exclusion from switch bursts. |

## Verification

`xcodebuild test` passed with **630 tests, zero failures**, with signing disabled,
the repository's resolved dependency versions, and serial macOS tests. Regression
coverage includes cancellation/draining, failed adjacent recovery, exact fallback
arrival, missing/unrelated notifications, full-screen fallback, malformed topology,
display ordering, disconnected displays, focus candidate changes, delayed placement,
offscreen restore, hidden-Space multi-window selection, malformed app responses,
and stale snapping state.
`git diff --check` passed.

The tests inject Space state, event posters, private-API backends, and scheduling
for deterministic verification. They do not establish live WindowServer throughput
or guarantee private-API behavior on every OS version. No real desktop switch,
window migration, Dock restart, or application replacement was performed for this
audit. Older OS versions, physical multi-display disconnects, mirrored layouts,
Stage Manager/full-screen combinations, and sustained rapid shortcut input still
need manual app-level testing.
