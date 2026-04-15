# Transcribe (Native macOS SwiftUI)

This repository now contains a native macOS SwiftUI transcription app that replaces the previous Streamlit UI.

## What It Does

- Transcribes **audio or video** files.
- Supports two modes:
  - **Local** (default): runs `python3 -m whisper` on your machine.
  - **API** (optional): uses OpenAI transcription endpoint with your API key.
- Detects Mac physical RAM and recommends a local model profile:
  - Light / Medium / Large (user can override anytime).
- Supports language selection (`Auto Detect` + common Whisper languages).
- Optional speaker separation in local mode (experimental) using WhisperX diarization.
- Diarization setup is explicit in Settings via **Install Diarization Models** (token + dependency verification) before speaker separation can be enabled.
- Optional streaming transcript updates during local transcription (enabled by default).
- Output styles:
  - `Original`
  - `Romanized` (system transliteration)
  - `Hinglish` (best-effort Hindi/English roman output)
- Main window includes drag/drop input, start/stop controls, progress bar, chat-style transcript view, and export.
- Transcript sessions are created at start and updated live; history supports rename/delete and persists across app restarts.
- App opens in a **new chat** state by default (no preselected old transcript).
- Advanced controls (mode/model/API key/language/output style) live in the **Settings** window.
- Exports transcript to **DOCX** and **PDF**.
- Uses bundled `logo_transcribe.png` as runtime Dock icon.

## Project Layout

- `Package.swift`
- `Sources/TranscribeMacApp/App/*`
- `Sources/TranscribeMacApp/Views/*`
- `Sources/TranscribeMacApp/Models/*`
- `Sources/TranscribeMacApp/Services/*`
- `Sources/TranscribeMacApp/Resources/logo_transcribe.png`

## Prerequisites

### For Local Mode (default)

- macOS with Xcode command line tools
- Python 3
- FFmpeg (used for video-to-audio preparation):
  ```bash
  brew install ffmpeg
  ```
- For source/dev runs (`swift run`), install whisper runtime locally:
  ```bash
  pip install -U openai-whisper
  ```
- For speaker separation in local mode, use the in-app diarization setup flow in Settings.

### For API Mode (optional)

- OpenAI API key

## Build

```bash
swift build
```

## Run

```bash
swift run TranscribeMacApp
```

## Package Installer

```bash
./script/package_app.sh
```

This produces:
- `dist/Transcribe.app`
- `dist/Transcribe-Installer.pkg`
- `Transcribe-Installer.pkg` (copied from `dist/` to project root)

Distribution output is **PKG only**. No DMG is produced.

Packaging behavior:
- `ffmpeg` resolution order is: `TRANSCIBE_FFMPEG_PATH` override, `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, then `command -v ffmpeg`.
- The app always bundles `ffmpeg` at `dist/Transcribe.app/Contents/Resources/bin/ffmpeg`.
- `dist/Transcribe-Installer.pkg` installs the app to `/Applications`, creates `/Library/Application Support/Transcribe/venv`, and installs `openai-whisper` automatically during postinstall.
- Speaker diarization setup remains opt-in from Settings via **Install Diarization Models**.
- If you only drag `Transcribe.app` into Applications (without running the pkg), local mode may still need manual Python/Whisper setup.
- The latest `.pkg` is copied to the project root for quick sharing/discovery.

If `pkgbuild` is unavailable, packaging fails with an explicit error because the `.pkg` is a required output.

If you want to force a specific `ffmpeg`, set `TRANSCIBE_FFMPEG_PATH` before running the script.

```bash
TRANSCIBE_FFMPEG_PATH=/opt/homebrew/bin/ffmpeg ./script/package_app.sh
```

## How to Use

1. Launch the app.
2. Drag/drop an audio/video file (or click **Choose File**).
3. Use the top-left **New Chat** button to reset the viewport at any time.
4. Open **Settings** (`Transcribe > Settings` or `Cmd+,`) to change mode/model/language/output and run diarization model setup.
5. Click **Start Transcription** and monitor the progress bar.
6. During transcription, use **Stop** or **Stop & Save Partial** as needed.
7. Use saved transcript history to switch, rename, or delete previous transcripts.
8. Export transcript as **DOCX** or **PDF**.

## Notes

- Local transcription quality/performance depends on installed Whisper model and machine resources.
- Speaker separation requires a successful in-app diarization setup (Hugging Face token + dependency verification) and is marked experimental.
- API mode sends selected media to OpenAI transcription endpoint.
- Hinglish output is best-effort transliteration/post-processing, not full language rewriting.
- Quitting the app while a transcription is running shows a confirmation dialog; choosing **Cancel** keeps the task running.

## License

MIT (see [LICENSE](LICENSE)).
