# Contributing to LiteDictate (言落)

Thank you for your interest in contributing to **LiteDictate**!

## Architectural Guardrails

LiteDictate is engineered specifically for **8 GB Apple Silicon Macs (macOS 14.0+)**. Please keep these non-negotiable invariants in mind for all pull requests:

1. **Pure AppKit UI Only**: `Sources/LiteDictateApp/` must NOT import `SwiftUI` or `WebKit`. Every panel/window (`RecordingOverlay`, `RecoveryPanel`, `SettingsWindowController`) must be created lazily and torn down completely on hide/close to keep idle `phys_footprint <= 20 MB`.
2. **Strict Core / UI Separation**: `Sources/LiteDictateCore/` contains all state machines and exposes only immutable `AppStateSnapshot` projections + `AppActionCommand` dispatches to the UI shell.
3. **macOS 14.0+ Compatibility**: Use `Sources/CLiteDictateAtomics/` (`AtomicBool`, `AtomicUInt64`) rather than macOS 15-only `Synchronization.Atomic`, and guard macOS 15.4+ APIs (`NSPasteboard.accessBehavior`) with `#available`.
4. **Realtime Audio & Privacy Rules**:
   - The C11 `AUHAL` render callback (`Sources/CLiteDictateAudio/`) must stay 100% free of heap allocations, locks, Objective-C, Swift ARC, and blocking syscalls.
   - Never log transcribed text or user prompts anywhere.
   - Never commit `*.dylib`, `*.gguf`, or `Build/` artifacts.
5. **8 GB RAM Build Discipline**: Always pass `-j 2` to `swift build`, `swift test`, and `cmake --build`, and never run concurrent Metal inference workers.

## Local Development Setup

```bash
# 1. Stage & SHA-256 verify native transcribe.cpp dylibs into Build/Engine/
./Scripts/fetch-transcribe-cpp.sh

# 2. Run all Swift tests
swift test -j 2

# 3. Build & verify C++17 worker + probe
JOBS=2 ./Scripts/build-app.sh --worker-only
./Build/Worker/worker-probe

# 4. Build full Release LiteDictate.app & styled DMG
JOBS=2 ./Scripts/build-app.sh
./Scripts/build-dmg.sh
```

To sign with a specific Apple Developer identity, set `SIGN_IDENTITY="Apple Development: ..."` or `SIGN_MODE=adhoc`.

## Pull Request Checklist

- [ ] `swift test -j 2` passes with 0 warnings and 0 failures.
- [ ] `otool -L Build/LiteDictate.app/Contents/MacOS/LiteDictateApp` shows zero `SwiftUI` / `WebKit` linkage.
- [ ] New behaviors include deterministic unit tests (no live TCC or hardware flakiness on clean checkouts).
- [ ] `git status` contains no `.dylib`, `.gguf`, or `Build/` artifacts.
