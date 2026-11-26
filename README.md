<p align="center">
  <img src="Resources/AppIcon.svg" width="96" alt="LiteDictate (言落) App Icon" />
</p>

<h1 align="center">LiteDictate（言落）</h1>

<p align="center">
  <strong>Ultra-light, 100% offline macOS native voice dictation — direct clipboard-free typing, ~12.5 MB idle RAM, zero Bluetooth HFP audio drop, BYO GGUF.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-0f172a?logo=apple&logoColor=white" alt="macOS 14.0+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%20--%20M4-1d4ed8" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Idle%20RAM-~12.5%20MB-059669" alt="12.5 MB Idle RAM" />
  <img src="https://img.shields.io/badge/Release-v1.0.0-6366f1" alt="Release v1.0.0" />
  <img src="https://img.shields.io/badge/License-MIT-475569" alt="MIT License" />
</p>

<p align="center">
  <a href="README_ZH.md">简体中文文档 (README_ZH.md)</a> ·
  <a href="https://github.com/MiohalationM/LiteDictate/releases">Download v1.0.0 DMG</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

## Highlights

- **Direct Natural Typing (Zero Clipboard Touch)**: Inserts recognized text straight into the active text field — your clipboard stays 100% untouched (no overwritten images, passwords, or clipboard-history spam). An optional Clipboard Compatibility Mode is still available in Preferences for rare legacy apps.
- **Built for 8 GB Macs (`~12.5 MB` Idle, `0 MB` Model RAM When Idle)**:
  - Pure native **AppKit** menu bar shell & lazy-loaded Preferences window (zero Electron, zero SwiftUI, zero WebView; windows are fully torn down when hidden/closed).
  - Disposable C++17 `litedictate-worker` child process frees inference buffers immediately after each utterance and exits cleanly after 60s idle (or immediately under macOS memory pressure), returning **0 MB** inference memory to the OS.
  - Zero periodic polling wakeups once permissions are granted (`0.00 pkg_idle_wakeups/s`, `0.038%` idle CPU).
- **Zero Bluetooth HFP Audio Degradation**: Input-only CoreAudio `AUHAL` with **Smart Microphone Selection** (`USB/Thunderbolt > Built-In`, skipping Bluetooth/Continuity/Virtual mics) so listening to music or calls on AirPods never switches to muffled HFP/SCO. Manual device pinning by stable `AudioDeviceUID` is also supported with transparent hotplug fallback and auto-recovery.
- **Bring Your Own GGUF Model**: Import any `transcribe.cpp`-compatible `.gguf` speech model directly in Preferences or the menu bar — **Qwen3-ASR**, **Whisper**, **SenseVoice**, **FunASR-Nano**, **Parakeet**, **Moonshine**, **Voxtral**, **Granite Speech**, and **Canary**. Reference models in-place with zero extra disk copy, or copy them into Application Support.
- **Privacy-First & Everyday Polish**:
  - 100% offline local inference, zero telemetry, zero transcript logging, immediate audio memory wipe on commit/cancel/lock/sleep/quit.
  - Configurable global shortcut (default `⌘⇧D`, visual shortcut recorder in Preferences, Toggle or Push-to-Talk), lock-free `Esc` cancel (never breaks Vim/IDE `Esc`), Terminal newline/control-character safety guard, Secure Input / password-field pause, Recovery Card for interrupted focus, and native macOS `SMAppService` Launch at Login.

---

## Real-Machine Benchmark (Apple M1, 8 GB Unified RAM)

Measured natively on **Apple M1 (8 GB RAM)** via `proc_pid_rusage` / `task_info(TASK_VM_INFO)` with `LiteDictate v1.0.0` + `Qwen3-ASR-0.6B-Q8_0.gguf` (811 MiB, `no_mmap = false`, Metal GPU):

| Metric | Measured Result | Notes |
| :--- | :---: | :--- |
| App Shell Idle `phys_footprint` | **`12.50 MB`** | Pure AppKit Release build (lazy overlay/recovery/preferences teardown) |
| Idle CPU / Package Wakeups (10s steady) | **`0.038%` / `0.00/s`** | Zero background polling timers once authorized |
| Cold State Inference RAM | **`0 MB`** | Worker process exits cleanly after 60s TTL (unloads in **`29.9 ms`**) |
| Warm Standby Worker `phys_footprint` | **`81 – 103 MB`** | Read-only `mmap` weights; session freed after every utterance |
| Active Inference Peak `phys_footprint` | **`310 – 330 MB`** | Ephemeral Metal compute graph + KV buffer freed immediately after |
| Speech-to-Text Speed (Metal GPU) | **`3.5× – 13.3×` realtime** | 2–15s mixed Chinese/English utterances finish in ~250 ms – 1.3 s |

---

## Installation

### Option 1 — Download Prebuilt DMG (Recommended)

1. Download **`LiteDictate-1.0.0-arm64.dmg`** from [GitHub Releases](https://github.com/MiohalationM/LiteDictate/releases).
2. Open the DMG and drag **LiteDictate** into **Applications**.
3. Launch **LiteDictate** from Applications (for locally self-signed / unnotarized builds, clear Gatekeeper quarantine once via `xattr -cr /Applications/LiteDictate.app`).
4. Click the menu bar waveform icon → **开启系统权限以开始使用…** to grant Microphone, Input Monitoring, and Accessibility, then import a `.gguf` ASR model (e.g. `Qwen3-ASR-0.6B-Q8_0.gguf`, `whisper-small.gguf`, or `SenseVoice-Small.gguf`).

### Option 2 — Build from Source (macOS 14.0+, Apple Silicon)

Prerequisites: Xcode Command Line Tools (Swift 6.0+), CMake, Ninja.

```bash
git clone https://github.com/MiohalationM/LiteDictate.git
cd LiteDictate

# 1. Fetch & SHA-256 verify transcribe.cpp v0.4.1 arm64-metal dylibs (never committed to Git)
./Scripts/fetch-transcribe-cpp.sh

# 2. Run all Swift unit tests (8 GB RAM friendly concurrency)
swift test -j 2

# 3. Build & sign Release LiteDictate.app (auto-selects local Developer cert or ad-hoc `-`)
JOBS=2 ./Scripts/build-app.sh

# 4. (Optional) Package styled LiteDictate-1.0.0-arm64.dmg + SHA256SUMS.txt
./Scripts/build-dmg.sh
```

---

## Custom Hotwords & Aliases

Edit directly inside **Preferences → 词库与权限**, or modify files in `~/Library/Application Support/LiteDictate/`:
- `vocab.txt` — one hotword per line (up to 50 entries; dynamically mapped to model capabilities)
- `aliases.json` — deterministic longest-key-first replacements (e.g. `{"Swift UI": "SwiftUI", "LightDictate": "LiteDictate"}`)

## License

MIT License — see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
