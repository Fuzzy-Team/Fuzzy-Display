# Fuzzy Display

A reduced fork of [DeskPad](https://github.com/Stengo/DeskPad), used by Fuzzy Macro to give one Roblox client a 1920x1080 game area at 1x scale. Based on DeskPad commit c3349f0e237e000cb4826fb3ea1cdd1c44949461. DeskPad's MIT license and the original display declarations are retained.

The helper keeps Roblox windowed on an extended virtual monitor. The monitor includes space for native window decorations and the menu bar/Dock. Its single 60 Hz mode is resized to accommodate those measured insets. The helper measures Roblox's native title bar through Accessibility and verifies the outer window's position and size against the requested game area. A borderless, noninteractive preview shows only the game on the physical display, preserving aspect ratio without taking keyboard focus.

Requires macOS 13 or newer. It uses the same private CoreGraphics virtual-display APIs as DeskPad. OS updates can change those APIs. Accessibility and Screen Recording permissions are required for this helper, in addition to Fuzzy Macro's permissions.

## Build

Run `bash build.sh /absolute/output/directory` with the Xcode command-line tools installed. The script builds arm64 and x86_64, combines them into a universal app and produces FuzzyDisplay.tar.gz. The default signature is ad hoc for development; it is not Developer ID signed or notarized. Distribution on a clean Mac still needs Gatekeeper and permission testing. No launch is performed by the build.

Fuzzy keeps a pinned copy of the archive, its SHA-256 and source commit in its main repository. Update that artifact when updating this fork. Users do not need Xcode or a separate DeskPad installation.

## Integration protocol

Launch the app's Contents/MacOS/FuzzyDisplay executable with a private session directory and its owning GUI PID. `--version` prints the version without creating an app or display.

Fuzzy atomically writes command.json containing a unique id and an action. Actions are prepare, show, hide and quit. status.json reports protocol version 1, the completed command id, display and content rectangles in global Quartz points, window identity, readiness, error and heartbeat timestamp. Status is written atomically. Fuzzy serializes commands across its processes.

The helper owns one display until quit or parent exit. Normal macro Stop keeps that display alive. On orderly termination the helper restores the window placement/fullscreen state recorded before moving Roblox, including after a rejoin replaces the client process. It never kills Roblox or other app processes. Abrupt termination or WindowServer failure can prevent restoration.

## Validation status

Live checks on macOS 27.0.1, Apple Silicon verified a 1920x1080 game crop at 1x, fullscreen exit, native window calibration, Apple Vision OCR, mouse/keyboard targeting, replacement-client rejoin, borderless preview focus, hide/show and exact placement restoration. Three repeated start/hide/show cycles passed. MSS and file-based capture matched, including with the virtual monitor left of the primary display at a negative origin.

The preview is assigned to the primary display explicitly and sits above its menu bar. Pause/Stop can hide it without removing the virtual display. The external-window occlusion check excludes the system cursor and this helper's compositor backing windows, which macOS can extend one pixel past the preview's visible edge.

The test machine's physical monitor was non-Retina. Physical Retina hardware, Intel runtime, older supported macOS releases, sleep/wake and clean-machine Gatekeeper/permission setup remain untested. The universal binary compiles for both architectures and is ad hoc signed; it is not Developer ID signed or notarized. The full farming macro was not run during these focused display tests.
