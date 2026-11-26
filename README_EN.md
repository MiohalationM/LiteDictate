<p align="center">
  <img src="Resources/AppIcon.svg" width="88" alt="LiteDictate" />
</p>

<h1 align="center">LiteDictate（言落）</h1>

<p align="center">
  An ultra-light, completely offline voice typing tool for macOS — speak and the words appear.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-0f172a?logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1--M4-1d4ed8" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Idle-~13%20MB-059669" alt="~13 MB Idle" />
  <img src="https://img.shields.io/badge/License-MIT-475569" alt="MIT License" />
</p>

<p align="center">
  <a href="https://github.com/MiohalationM/LiteDictate/releases">Download</a> ·
  <a href="README.md">简体中文</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

## Why LiteDictate

- **Types right where your cursor is — clipboard untouched**: Recognized text goes straight into the active input box without overwriting copied images or text.
- **Featherweight on 8 GB Macs**: Uses only **~13 MB** of memory while waiting in the menu bar, and automatically frees the speech model when you stop talking.
- **No muffled Bluetooth headphones**: Automatically avoids switching Bluetooth headphones into call mode, so your music and calls stay crisp.
- **100% offline, bring your own model**: Works without internet and never uploads audio or text. Import any local `.gguf` speech model (Qwen3-ASR, Whisper, SenseVoice, and more).

## Quick Start

1. Download `LiteDictate-1.0.0-arm64.dmg` from [Releases](https://github.com/MiohalationM/LiteDictate/releases) and drag **LiteDictate** into **Applications**.
2. Click the menu bar icon to grant permissions and import a local `.gguf` speech model.
3. Press `⌘⇧D` anywhere to start speaking, press again to insert text, or press `Esc` to cancel.

## Tips

- If macOS warns on first launch, run once in Terminal: `xattr -cr /Applications/LiteDictate.app`.
- Open **Preferences** from the menu bar to change the shortcut, enable Launch at Login, switch to Push-to-Talk, or add custom words and auto-corrections.
- <details><summary>Build from source (Apple Silicon / macOS 14+)</summary>

```bash
git clone https://github.com/MiohalationM/LiteDictate.git && cd LiteDictate
./Scripts/fetch-transcribe-cpp.sh
JOBS=2 ./Scripts/build-app.sh
./Scripts/build-dmg.sh
```

</details>

## License

MIT — see [LICENSE](LICENSE).
