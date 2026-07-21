# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build          # Build the project
swift run            # Build and launch the app
open Package.swift   # Open in Xcode (Cmd+R to run)
```

There are no tests in this project.

**After making code changes, always run `swift run &` in the background to launch the app so the user can verify the changes immediately.**

### First-time setup

The pre-built `Frameworks/CWhisper.xcframework` is included. To rebuild from source:
```bash
bash Scripts/build_whisper_lib.sh    # Builds whisper.cpp with Metal+Accelerate → xcframework
```

Convert the Breeze-ASR-25 model (requires Python 3 + torch/transformers/numpy/huggingface_hub):
```bash
bash Scripts/convert_model.sh        # Downloads ~3 GB model → Models/ggml-model.bin
```

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages:

```
<type>: <short summary>
```

Types: `feat`, `fix`, `refactor`, `docs`, `chore`, `style`, `perf`, `test`, `build`, `ci`

Examples:
- `feat: add JSON persistence for transcriptions`
- `fix: restore pending items on app relaunch`
- `refactor: extract audio loading into AudioLoader`
- `docs: add AGENTS.md`

For breaking changes, add `!` after the type: `feat!: change transcription storage format`

## Architecture

Native macOS SwiftUI app (macOS 14+, arm64) that transcribes audio using whisper.cpp with Metal GPU acceleration. Built with Swift Package Manager.

### Data flow

`SidebarView` (drag-drop/file picker) → `AppState.addFile()` → `TranscriptionService.transcribe()` → whisper.cpp C API → results stored in `TranscriptionItem` → persisted by `TranscriptionStore`

### Key layers

- **C interop** (`TranscriptionService`): Bridges Swift to whisper.cpp C API. Manages model lifecycle (`whisper_init`/`whisper_free`), runs `whisper_full()` on a background dispatch queue, uses `withCheckedThrowingContinuation` to bridge C callbacks to async/await. Progress is reported via a `ProgressBox` wrapper that passes Swift closures through C function pointers.

- **State** (`AppState`): Single `@Observable` object injected via SwiftUI environment. Owns the `TranscriptionService` and the item collection. Orchestrates transcription lifecycle (add → transcribe → save, or retry/remove).

- **Persistence** (`TranscriptionStore`): JSON file-per-item storage in `~/Library/Application Support/WhisperASR/Transcriptions/`. Saves on completion/failure/removal. Items mid-transcription at quit restore as "pending".

- **Audio** (`AudioLoader`): Converts any audio/video to 16 kHz mono Float32 PCM via `AVAssetReader`, falling back to `ffmpeg` (if found in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, or `PATH`) for containers macOS can't decode natively — notably WebM/Opus from browser `MediaRecorder`, which the OpenAI API server commonly receives. `AudioPlayerManager` wraps `AVPlayer` for playback with periodic time observation for synced transcript highlighting.

- **API server** (`APIServer`): Optional OpenAI-compatible HTTP server (built on [FlyingFox](https://github.com/swhitty/FlyingFox), the only external SPM dependency). `APIServer.shared` is a `@MainActor @Observable` singleton that `AppState` injects its `TranscriptionService` into (via `attach`) so the model loads once and all requests serialize on the existing whisper queue. Serves `POST /v1/audio/transcriptions`, `POST /v1/audio/translations`, and `GET /v1/models`; supports `json`/`verbose_json`/`text`/`srt`/`vtt` response formats. Config (enable, port, optional bearer token, LAN binding) lives in UserDefaults / `SettingsView`; the token is read per-request so it takes effect without a restart, while port/LAN changes require toggling off and on. Multipart parsing is hand-rolled in `MultipartParser`.

### UI structure

`ContentView` is a `NavigationSplitView` with `SidebarView` (file list) + `DetailView` (status-dependent: progress/transcript/error) + `PlayerView` (audio controls, shown when a completed item is selected). `TranscriptContentView` syncs segment highlighting with audio playback position via `ScrollViewReader`.

### Model resolution

`ModelCatalog` defines the downloadable models (Breeze-ASR-25 plus official whisper.cpp tiny/base/small/medium/large-v3-turbo); `ModelManager` (shared `@Observable`) tracks downloaded files in `~/Library/Application Support/WhisperASR/Models/`, per-model `ModelDownloader` instances, and the active selection (UserDefaults `"selectedModelFile"`, settable from `SettingsView` or the toolbar `ModelPickerMenu`).

`TranscriptionService.resolveModelPath()` checks `"selectedModelFile"` first, then the custom `"modelPath"` (set via `SettingsView`), then the App Support default `ggml-model.bin`, then falls back to `{projectRoot}/Models/ggml-model.bin` using `#filePath` to locate the project root. The model is lazily (re)loaded whenever the resolved path changes, so switching models takes effect on the next transcription.
