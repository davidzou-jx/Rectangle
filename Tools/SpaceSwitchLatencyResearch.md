# Space switching latency and repeated commands

Research date: October 8, 2026. Code baseline: `cf4f6e6`.
Host: macOS 27.0, build 26A428. Measurements below describe the research baseline, before implementation.

The largest opportunities are to avoid the 150 ms cooldown after Rectangle's
own verified switches, check completion sooner, and retain repeated requests
instead of discarding them. Removing the 10 ms gesture-phase spacing should not
be the first optimization.

## Baseline delays

| Component | Current behavior | Effect |
| --- | --- | --- |
| `SpaceOperationCoordinator` | Every Space-change notification starts a 150 ms quiet period. | A completed Rectangle switch can still block the next command. Native and Rectangle changes receive the same treatment. |
| `SpaceSwitcher` gesture | Two 10 ms phase gaps on macOS 27. | The three-phase gesture takes at least 20 ms to submit. Earlier OS versions have no phase gap. |
| `SpaceSwitcher` confirmation | First check 60 ms after the final phase; subsequent checks every 50 ms. | Earliest normal completion is approximately 80 ms after starting on macOS 27, before query and scheduling overhead. |
| Display targeting | Wait 30 ms after warping the pointer to a different display. | Applies when an explicit target screen requires a pointer warp, including followed window moves. |
| `NumberedSpaceSwitcher` | First check after 50 ms; three successful checks, 50 ms apart. | Even an immediately completed switch holds its operation for at least 150 ms. |
| Window move focus/order | Three successful order/focus checks, 50 ms apart after the first raise. | A followed window move retains the shared operation longer than switching alone. It needs a separate performance investigation. |

The waits overlap. For adjacent switching, the next command must satisfy both
the switcher's completion check and the coordinator's quiet period:

```
next allowed = max(operation finished, last Space notification + 150 ms)
```

The coordinator's notification timestamp is not a reliable measure of completed
rendering. Apple's [notification documentation](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)
defines a Space-change notification, with no `userInfo` identifying the originating
command or a rendering-completion guarantee. Ownership must be established using
the operation, expected display/destination, fresh state, and interruption signals.

Both switchers discard commands while busy. The coordinator also rejects commands
during its quiet period. Repeated requests are not queued for later execution.
`SpacePhysicalInputMonitor` additionally treats key-down events as interruptions.
If a repeated registered shortcut reaches that monitor, adjacent switching can
be cancelled and numbered switching can lose its eligibility for rollback. The
actual ordering of Carbon hotkey callbacks and event-monitor delivery still needs
an app-level test; this is a potential issue, not an observed live failure.

## Controlled timing model

An isolated Swift executable compiled the unchanged production `SpaceSwitcher`,
`NumberedSpaceSwitcher`, `SpaceOperationCoordinator`, and gesture definitions.
Injected event posters and activation backends changed mock state immediately;
a virtual scheduler delivered notifications and attempted a new request every
1 ms. It posted no real gesture and performed no real Space activation.

| Model scenario | Operation released | Next request accepted |
| --- | ---: | ---: |
| Adjacent: current settings; notification at final phase | 80 ms | approximately 170 ms |
| Adjacent: current settings; notification 60 ms after final phase | 80 ms | approximately 230 ms |
| Adjacent: settle wait reduced to 10 ms; current cooldown | 30 ms | approximately 170 ms |
| Adjacent: current settle wait; cooldown disabled | 80 ms | 80 ms |
| Adjacent: 10 ms settle wait; cooldown disabled | 30 ms | 30 ms |
| Numbered: current settings; notification at submission | approximately 150 ms | approximately 150 ms |
| Numbered: current settings; notification 80 ms after submission | approximately 150 ms | approximately 230 ms |

Floating-point virtual-clock boundaries account for a 1 ms difference in several
raw results. These results establish the effect of Rectangle's timers; they do
not establish that the Dock can safely sustain a switch every 30 ms.

## Read-only measurements

The same executable measured actual production topology, visibility, runtime
signature, and Mission Control checks. Accessibility was authorized and the
bridged backend was available. Each measurement used five warm-up calls followed
by 60 samples. The visibility check used the currently displayed desktop and a
different, inactive normal desktop on that display, exercising the full check
without switching. Only one display had an eligible comparison pair.

| Query | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Managed-display topology | 0.091 ms | 0.121 ms | 2.033 ms |
| Bridged operation signature availability | 0.002 ms | 0.002 ms | 0.002 ms |
| Dock AX Mission Control check | 0.314 ms | 0.375 ms | 0.383 ms |
| Destination visibility | 0.498 ms | 2.000 ms | 3.395 ms |

On this idle machine the fixed waits dominate these read costs. This does not
bound query times under load or with more windows. The Dock AX messaging timeout
is 50 ms per call, so synchronous checks can still stall a busy main queue.

## Comparison with primary sources

[Tinycast's switcher](https://github.com/abue-ammar/tinycast/blob/9e6beba99aacedf50bbf42c1a5107b981ffb37ab/Tinycast/Features/WindowManagement/Service/SpaceSwitcher.swift)
releases its gesture lock after posting the final phase, without Rectangle's
additional settle or notification cooldown. Its
[gesture implementation](https://github.com/abue-ammar/tinycast/blob/9e6beba99aacedf50bbf42c1a5107b981ffb37ab/Tinycast/Features/WindowManagement/Model/SpaceGesture.swift)
documents double moves from back-to-back phases on macOS 27 and retains 10 ms
spacing. It also reports that increasing velocity can overshoot. This supports
optimizing post-submission waits first, while retaining phase spacing and velocity.

[InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS/ISS.c)
posts gesture phases without explicit spacing, but maintains predicted per-display
destinations during bursts. Its comments describe stale intermediate Space IDs
causing overshoot beyond the last desktop and a temporarily stuck Dock on macOS
27. Its one-second prediction lifetime preserves intent; it is not a one-second
delay before another command. This is evidence that burst handling needs boundary
tracking and reconciliation, not just smaller timers.

[Yabai's display checks](https://github.com/asmvik/yabai/blob/master/src/display_manager.c)
explicitly avoid relying on `SLSManagedDisplayIsAnimating` on modern macOS because
it gives incorrect results. Replacing the cooldown with that query alone would
not establish safety.

Rectangle's pinned
[MASShortcut monitor](https://github.com/rxhanson/MASShortcut/blob/2f9fbb3f959b7a683c6faaf9638d22afad37a235/Framework/Monitoring/MASShortcutMonitor.m)
dispatches each received Carbon hotkey-pressed event onto the main queue without
an explicit debounce. The visible application delays originate in Rectangle's
Space machinery. Holding a key also depends on macOS delivering repeat events;
this research did not measure the system's initial key-repeat delay.

## Recommended implementation

1. **Retain pending switch intent.** Serialize real operations, but remember rapid
   shortcut presses while one is in progress. For relative commands, advance a
   bounded intended target using the display's Space order, clamping each press at
   its boundary. Do not simply sum directions: at the last desktop, Next then
   Previous must move back one desktop. Numbered commands can replace the pending
   target with the latest requested desktop. Reconcile against fresh topology
   before submission, and capture the target display when each request arrives.
2. **Separate owned completion from native settling.** Keep protection against
   native switches and Mission Control, but let a verified Rectangle switch hand
   its operation directly to a pending switch without another 150 ms wait.
   Track expected display and Space IDs, and handle delayed/ambiguous notifications.
   A burst can retain its operation across verified switches. Also provide a fast
   path for a new press just after a verified operation completes, provided state
   still matches and no external input intervened. Globally setting the existing
   quiet period to zero would remove protections used by window moves too.
3. **Check actual completion sooner.** Replace the adjacent switch's 60 ms first
   wait and 50 ms retries with notification-triggered checks and an approximately
   10 ms fallback poll. Confirm the expected destination, rather than merely any
   change from the original ID. For direct switches, retain visibility checking
   and initially keep three stable samples, but use approximately 10 ms spacing.
   Use an elapsed-time deadline: keeping the current poll count while shortening
   its interval would also shorten the failure timeout unintentionally.
4. **Distinguish repeat intent from interruption.** Only the matching registered
   Space shortcut should extend/update a burst. Other keys, clicks, real gestures,
   Mission Control, and unrelated Space changes must cancel pending intent and
   delayed focus restoration. Do not ignore all keyboard input.
5. **Prefer explicit bridged targets where already supported.** For adjacent
   normal-to-normal desktop switching on compatible macOS, the existing bridged
   Show/Hide/SetCurrent backend could avoid gesture pacing and pointer warping.
   Keep the gesture path for unsupported systems and unverified full-screen
   transitions. Private operations are asynchronous: submission is not completion.

An approximately 30–60 ms repeat interval is a reasonable initial target to
evaluate for ordinary switch-only commands, based on the timing model and cheap
queries. It is not yet a measured safe live rate. Buffering presses would improve
responsiveness even when actual completion takes longer.

## Remaining validation

Measure real submission-to-ID, visibility, notification, focus, and next-accepted
times in the running app. Exercise rapid taps, held keys, reversals, first/last
desktop boundaries, numbered replacement, multiple displays, native gestures,
Mission Control, full-screen transitions, and interleaved window moves. Check for
double moves, old/new desktops visible together, incorrect focus, late callbacks,
and unwanted movement after the user stops.

No production code, system preference, window, or active desktop was changed during
the initial research. The standalone model and raw measurement log were saved under
`/private/tmp/rectangle-space-latency-research` for the current session.


## Implemented changes

`SpaceSwitchManager` now routes both adjacent and numbered switch-only commands.
It retains one destination per display, clamps each relative press against fresh
Space order, and replaces pending numbered destinations. It keeps the shared
operation across verified handoffs and permits a new burst to reuse a recently
verified all-display state for up to 300 ms. Native input invalidates that fast
path; window moves retain the existing 150 ms native-change guard. Unexpected
Space IDs, display removal, and topology reordering discard pending intent.

Normal-to-normal adjacent switches prefer the existing bridged backend. Relative
full-screen transitions and systems without that API keep the gesture fallback.
Numbered switches retain their existing direct-API requirement. Gesture phase
spacing remains 10 ms on macOS 27, and explicit display pointer targeting keeps
its 30 ms wait.

Both backends check completion on Space notifications and poll at 10 ms. Direct
switching retains three visibility samples separated by at least 10 ms. Gesture
bursts also require three exact-destination samples, checking visibility when the
read API is available. The confirmation deadline remains approximately 1.5 seconds
instead of shrinking with the polling interval. Failed direct switches retain
the existing owned recovery behavior; input or an external switch disables
rollback.

Deterministic regression tests model immediate direct completion in 30 ms without
a notification, or 20 ms with a notification supplying the first sample. A queued
two-switch burst completes in 60 ms or 40 ms respectively. These are scheduler
models, not measured live Dock throughput. App-level validation of rapid taps,
held keys, display changes, and native full-screen behavior remains necessary.

Verification: `xcodebuild test` completed successfully with 599 tests, including
regressions for reentrant recovery notifications and external changes at the
confirmation deadline. The final tracked diff passed `git diff --check`.
