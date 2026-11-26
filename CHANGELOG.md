# Changelog

All notable changes to **LiteDictate (言落)** are documented in this file.

## [1.0.0] - 2026-11-26

### Highlights
- **Direct Clipboard-Free Text Insertion**: Natural two-tier text input (verified Accessibility insertion for native fields + smooth Unicode keystroke streaming with non-`kVK_ANSI_A` inert virtual key `0x00FF` and emoji surrogate-pair support) that never touches `NSPasteboard` by default, plus an optional Clipboard Compatibility Mode in Preferences.
- **8 GB Apple Silicon Memory Discipline**: Pure AppKit UI shell with 100% lazy window creation & full teardown (`~12.5 MB` live idle `phys_footprint`), zero-wakeup authorized idle (`0.00 pkg_idle_wakeups/s`, `0.038%` CPU), and disposable C++17 `litedictate-worker` (releases inference buffers immediately after each utterance, unloads to `0 MB` after 60s TTL or macOS memory pressure).
- **Zero Bluetooth HFP Degradation**: Input-only CoreAudio `AUHAL` capture with lock-free C11 SPSC ring buffer, Accelerate `vDSP` multi-channel pre-downmix, and Smart Microphone Selection (`USB/Thunderbolt > Built-In`, skipping Bluetooth/Continuity/Virtual mics) alongside manual `AudioDeviceUID` pinning with hotplug fallback & auto-recovery.
- **BYO GGUF Model Support**: Import any `transcribe.cpp`-compatible `.gguf` ASR model (Qwen3-ASR, Whisper, SenseVoice, Parakeet, FunASR-Nano, Moonshine, Voxtral, Granite Speech, Canary) in reference (zero-copy) or atomic-copy mode, validated via `0x06 PROBE_MODEL` with symlink/inode deduplication and a 4 GiB safety cap.
- **Native macOS UX & Privacy**:
  - Frosted-glass floating recording pill with 5-bar animated brand waveform and frosted interactive Recovery Card.
  - Pure AppKit Preferences window (`通用` with visual shortcut recorder, `语音模型`, `麦克风`, `词库与权限`).
  - Active macOS TCC permission pulling, native `SMAppService.mainApp` Launch at Login, Terminal newline/control-char safety gate, Secure Input pause, `复制上一次识别文字` safety net (5-min memory-only TTL), and zero transcript logging.
- **Reproducible Open-Source Build & DMG Packaging**: SHA-256 pinned `Scripts/fetch-transcribe-cpp.sh`, portable `Scripts/build-app.sh` (auto-detects Developer cert or falls back cleanly to ad-hoc signing, embeds `LICENSE` & `THIRD_PARTY_NOTICES.md`), and styled `Scripts/build-dmg.sh` producing `LiteDictate-1.0.0-arm64.dmg` + `SHA256SUMS.txt`.
