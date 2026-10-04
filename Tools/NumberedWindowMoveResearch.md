# Numbered window moves: feasibility

Both numbered window moves and numbered moves with a destination switch are
feasible using the APIs already in this branch. They are now implemented as
Move to Desktop 1–9 in `BridgedSpaceManager`, with their own follow setting.

## Existing implementation

- `SkyLightWindowSpaceTransfer.move(windowID:to:)` accepts an explicit Space ID.
  The adjacent-only restriction comes from the caller's destination selection,
  rather than the transfer API.
- `ManagedSpaceTopology.desktop(number:in:)` already resolves Desktop 1–9 to
  current normal-Space IDs and display identifiers. Reuse this numbering for
  window commands; do not interpret the desktop number as the WindowServer ID.
- `SkyLightDisplaySpaceActivation.activate(_:)` already submits the direct
  WillSwitch/Show/Hide/SetCurrent sequence for a specified display and destination.
- `BridgedSpaceManager` already verifies window membership, raises the window
  without activation for background moves, and raises/activates it after followed
  moves. Its shared operation coordinator and interruption handling should also
  apply to numbered moves.

The current [Yabai move implementation](https://github.com/asmvik/yabai/blob/master/src/space_manager.c)
passes an explicit destination ID to `SLSBridgedMoveWindowsToManagedSpaceOperation`.
Its [window manager](https://github.com/asmvik/yabai/blob/master/src/window_manager.c)
separates moving a window from following it, and updates the destination Space's
front-process metadata. This corroborates the separation of transfer and focus;
it does not establish the correctness of Rectangle's combined operation.

## Live observations

Tested on macOS 27.0, build 26A428, with System Integrity Protection enabled.
The probe created its own ordinary window and used copies of Rectangle's actual
Swift transfer, topology-reader, and activation implementations. It restored the
window and every display's original current Space, then closed the window.

| Case | Observed result |
| --- | --- |
| Same-display move without follow | Membership changed from Space 10 to 9; the window became hidden; every display's active Space stayed unchanged; zero Space-change notifications. |
| Same-display move with follow | Membership changed to Space 9; that display became current on 9; the window became visible; one Space-change notification. |
| Nonadjacent numbered move | Desktop 2 to Desktop 5 (Space 10 to 8) worked in both modes, with the same membership and visibility results. |
| Cross-display move without follow | Membership changed from Space 10 to 44, the window's managed display changed, and both displays retained their original current Spaces (10 and 349). The destination was inactive and the window was hidden. |
| Cross-display move with follow | Window membership was 44 and the destination display switched from 349 to 44. The source display remained on 10, and the window became visible. |
| Destination stacking | After an explicit raise, the probe window was first among ordinary windows on the destination Space. |

Keyboard-focus restoration was **not verified**. Neither the command-line probe
nor its temporary app bundle obtained keyboard focus at baseline, before any
window transfer. Their missing key window after the switch cannot establish that
the switch lost focus. A production-app focus test is still required.

## Implementation implications

1. Resolve the numbered normal destination from fresh topology for each command.
   Preserve the existing exclusions for native full-screen, modal, sheet,
   minimized, and multi-Space windows. Missing destinations should do nothing.
2. For move-only, submit only the window transfer, verify its exact membership,
   and raise it without activating its app or switching desktops.
3. For move-and-follow, submit the transfer and direct display activation together,
   verify membership and the destination's visibility, then reuse the existing
   stacking and keyboard-focus confirmation path. The two APIs are asynchronous;
   issuing them consecutively is not proof of an atomic visual transition.
4. For cross-display moves, keep the window's source Space distinct from the
   destination display's previously current Space. The latter is the Space to
   hide or restore during display activation. Window placement on differently
   sized displays needs further validation.
5. Both modes should retain one shared operation through verification and stop
   delayed raises or recovery when the user intervenes.

Move to Desktop 1–9 uses **Switch to the destination desktop after a numbered
window move** in General > Across Display Settings. This is on by default and
independent of the Next/Previous Space move setting. Switch to Desktop 1–9
continues to switch without moving a window.

Full-screen transitions, cross-display placement, keyboard focus, and visual
flicker need app-level validation. The live results confirm transfer and final
desktop visibility, rather than every intermediate rendered frame. These remain
private runtime APIs, so availability/signature checks are required.
