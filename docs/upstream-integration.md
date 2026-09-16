# Upstream v0.10.0 integration

Upstream: https://github.com/plateaukao/whisperASR

- Previous shared commit: `a6a0d2004844750a2bae12d379cc38a040ea0681` (v0.6.1).
- Integrated tip: `ea3df23c7c23e685617b372789977e7080d52610` (v0.10.0).
- Local baseline: `01f7211`.
- All 17 upstream commits are retained in merge history, including the merge commit.

## Integration decisions

- Keep the read-only native text document and live selection mapping. Port the
  upstream last-line clearance without reverting to a per-segment List.
- Keep bounded PCM windows, incremental transcript publication, durable recovery,
  session ownership and bounded retries with actionable warnings.
- Integrate interim translation into the existing single-flight worker. Translate
  only the bounded mutable tail on a two-second throttle; final sealed batches
  advance the cursor, interim batches do not. Never concatenate all history on
  each audio update. Finish waits only for outstanding sealed translations.
- Dedicated live Whisper contexts share the cancellable native serial executor.
  A recording made with a different live model is filed as a draft, then queued
  for the main-model pass without dropping the visible draft or translations.
- Nemotron uses a separate bounded serial executor. Timeout/cancellation releases
  the caller but retains the physical slot until the async engine returns, avoiding
  actor reentrancy between load, reset, inference and cleanup. Mandarin output is
  normalized to Simplified Chinese; language preferences are passed to the engine.
- Speaker labeling has task ownership checks, so canceled work cannot modify a
  removed/retranscribed item or clear the state of its replacement task.
- Keep local release packaging/signing behavior, advance version to 0.10.0.

## Verification

Build with `swift build` and `swift build -c release`. Independent fixture checks
live in `Tests/LiveAudioChecks.swift`, `Tests/LiveTranscriptChecks.swift`,
`Tests/TranscriptionCancellationChecks.swift`, `Tests/LiveSessionChecks.swift`, and
`Tests/UpstreamFeatureChecks.swift`; each lists its standalone compilation command.
These exercise real buffer, assembler, AppState, text-view and executor code with
model/network/storage boundaries stubbed where appropriate.

Real Nemotron/diarization model inference, paid remote API calls, microphone/system
capture permissions and hour-long capture require manual validation. Models are
not downloaded automatically as part of this integration. The installed
`/Applications/WhisperASR.app` is not replaced by a source merge or `swift build`.

## Future upstream updates

`origin` remains the fork; `upstream` tracks the original repository. Fetch with
`git fetch upstream`, inspect `git log HEAD..upstream/main`, and merge on a fresh
integration branch. Preserve the decisions above when resolving future conflicts.
