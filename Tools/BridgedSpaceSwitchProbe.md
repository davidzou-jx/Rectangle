# Direct bridged Space-switch prototype

This probe implements `SLSBridgedManagedDisplaySetCurrentSpaceOperation` and its
companion `WillSwitchSpaces`, `ShowSpaces`, and `HideSpaces` operations. It is
isolated from Rectangle's application target. `NumberedSpaceSwitcher.swift` uses the
verified four-operation sequence for the numbered desktop commands.

Build and inspect without switching:

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Cocoa \
  Tools/BridgedSpaceSwitchProbe.m -o /private/tmp/rectangle-bridged-space-probe
/private/tmp/rectangle-bridged-space-probe
```

Choose the display by positioning the pointer over it. The probe selects another
populated normal desktop on that display; full-screen Spaces are excluded. These
modes briefly change the displayed desktop, then restore its original Space ID
and window visibility:

```sh
/private/tmp/rectangle-bridged-space-probe --setter-only
/private/tmp/rectangle-bridged-space-probe --round-trip
```

It checks runtime method signatures before calling the private API and handles
SIGINT/SIGTERM by restoring the original desktop. A successful round trip proves
the Space ID changed, destination windows became visible, source windows became
hidden, and the original visibility returned. It does not prove a complete native
Space switch. Window counts exclude windows assigned to multiple Spaces, which
otherwise could make an unsuccessful switch appear successful.

## Observed on macOS 27.0, build 26A428

- Unlike the [published reverse-engineered header](https://gist.github.com/stephancasas-openai/1b31a8d76c6a103e4676ac196e06e9d8),
  the setter inherits from `SLSAsynchronousBridgedWindowManagementOperation` and
  `performWithWMBridgeDelegate` returns `void`. Submission is not an acknowledgement.
- The setter alone changed the reported Space ID but left both desktops' windows
  visible. Setting the original ID back also left the destination windows visible.
  Cleanup therefore needs the companion show/hide operations, even in setter-only mode.
- The four-operation sequence hid the source windows and displayed the destination:
  `sourceVisible=4, targetVisible=0` became `sourceVisible=0, targetVisible=5`, then
  returned to the original visibility after restoration.
- The first probe spun `NSRunLoop` without running the AppKit event loop. It
  observed no Space-change notifications, including for a successful normal Dock
  gesture. That was an invalid notification control. With `NSApplication.run()`
  and asynchronous stage callbacks, both the bridged sequence and the gesture
  delivered one notification on arrival and another on return.
- A normal return gesture after a bridged switch reached the expected original
  desktop, providing evidence that Dock's next/previous navigation remained
  consistent. The original window visibility was restored too.
- A live round trip compiled from Rectangle's production Swift switcher, backend,
  topology reader, input monitor, and operation coordinator confirmed Desktop 2
  to Desktop 1 and back, with destination visibility confirmed and two
  Space-change notifications.
- Computer-use Dock inspection timed out despite working access to System
  Settings; that timeout is not evidence of a Dock or operating-system failure.

Live validation covered normal desktops on macOS 27.0. Native full-screen
transitions, wallpaper changes, and rapid changes in display configuration need
manual validation. Rectangle's implementation confirms the destination and checks
for resident source windows still being visible, serializes numbered commands
with window moves/gestures, and avoids rollback after physical input or an
external Space change.
