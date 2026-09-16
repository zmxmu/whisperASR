# WhisperASR

原生 macOS 語音轉錄應用程式，使用 [Breeze-ASR-25](https://github.com/mtkresearch/Breeze-ASR-25)（針對台灣華語與語碼混用微調的 Whisper large-v2 模型），透過 [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 搭配 Metal GPU 加速進行轉錄。

![即時轉錄與雙語輸出](docs/screenshots/live_recording.png)

## 截圖

| 轉錄進度 | 雙語逐字稿 |
|---|---|
| ![轉錄進度](docs/screenshots/progress.png) | ![雙語逐字稿](docs/screenshots/transcript.png) |

| 應用程式選擇 | 設定 |
|---|---|
| ![應用程式選擇](docs/screenshots/recording.png) | ![設定](docs/screenshots/settings.png) |

## 功能

### 即時轉錄＋翻譯

- **應用程式音訊錄製** — 透過 ScreenCaptureKit 錄製任何執行中應用程式的音訊（M4A/AAC，48 kHz）
- **即時轉錄** — 錄音時同步顯示轉錄文字
- **即時翻譯** — 每段轉錄文字下方即時顯示翻譯，透過 OpenAI 相容 API 實現
- **智慧自動捲動** — 即時轉錄畫面自動跟隨最新段落
- **即時結果保留** — 停止錄音後直接保留即時轉錄結果，無需重新轉錄
- **Zoom 會議偵測** — Zoom 會議結束時自動提示停止錄音

### 檔案轉錄

- **拖放上傳** 音訊／影片檔案（MP3、WAV、M4A、MP4、AAC、FLAC、OGG、WMA、AIFF、CAF）
- **批次處理** — 一次佇列多個檔案
- **循序轉錄佇列** — 檔案依序一個一個轉錄

### 雙語輸出

- **轉錄後翻譯** — 一鍵將完成的逐字稿翻譯成任何設定語言
- **語言設定** — 自動偵測或手動指定來源語言；選擇目標翻譯語言
- **搜尋** — 側邊欄全域篩選所有轉錄，或按 Cmd+F 在逐字稿內搜尋並高亮顯示

### 播放

- **音訊播放** — 播放／暫停、進度條、前後跳 ±5 秒
- **同步高亮** — 播放時自動高亮目前句子
- **點擊跳轉** — 點擊任意段落即跳至該時間點

### 模型

- **內建模型下載** — 在 App 內直接下載模型：Breeze-ASR-25（最適合台灣華語）以及官方 whisper.cpp 模型，從 Tiny（78 MB）到 Large v3 Turbo（1.6 GB）
- **隨時切換** — 從工具列或設定選擇使用的模型，下次轉錄即生效
- **自訂模型路徑** — 也可在設定中指定目錄外的 `ggml-*.bin` 模型檔案

### 本機 API 伺服器（相容 OpenAI）

- **可直接替換的 OpenAI 轉錄 API** — 在設定中啟用本機 HTTP 伺服器，將任何相容 OpenAI 的用戶端指向 `http://127.0.0.1:8080/v1`；轉錄在裝置上以你選擇的模型執行
- **端點** — `POST /v1/audio/transcriptions`、`POST /v1/audio/translations`（將音訊翻譯成英文）與 `GET /v1/models`
- **回應格式** — `json`、`verbose_json`（含時間軸片段）、`text`、`srt` 與 `vtt`
- **可選 API 金鑰** — 可要求 `Bearer` 權杖，並可選擇開放區域網路內其他裝置存取

### 隱私與效能

- **Metal GPU 加速** — 透過 whisper.cpp 完全在裝置上執行，音訊不會離開你的 Mac
- **自備 API** — 翻譯支援任何 OpenAI 相容端點，包括本地模型
- **重新轉錄** 與 **失敗重試**，可複製錯誤訊息

## 系統需求

- macOS 14.0 以上
- Apple Silicon Mac（arm64）— 內含的 xcframework 為 arm64 版本
- Python 3 及 `torch`、`transformers`、`numpy`、`huggingface_hub`（僅自行轉換模型時需要；下載預先轉換的 GGML 檔案則不需要）

## 安裝設定

### 1. 建置 whisper.cpp（若尚未包含）

專案已內含預先建置的 `CWhisper.xcframework`。如需從原始碼重新建置：

```bash
bash Scripts/build_whisper_lib.sh
```

此指令會複製 whisper.cpp、以 Metal + Accelerate 建置，並封裝靜態函式庫為 xcframework。

### 2. 取得語音辨識模型

**方法 A（推薦）：** 直接啟動 App — 首次執行會提示下載模型（Breeze-ASR-25 或較小的 Whisper 模型），之後可在「設定 → 語音辨識模型」中新增、選擇或刪除模型。

**方法 B：** 直接從 HuggingFace 下載預先轉換的 Breeze-ASR-25 GGML 檔案（約 3 GB），放至 `Models/ggml-model.bin`：

```
https://huggingface.co/danielkao0421/Breeze-ASR-25-ggml/blob/main/ggml-model.bin
```

**方法 C：** 從原始模型自行轉換（需要 Python 3 及 `torch`、`transformers`、`numpy`、`huggingface_hub`）：

```bash
bash Scripts/convert_model.sh
```

此指令會從 HuggingFace 下載 Breeze-ASR-25 模型、複製所需的 repo，並將其轉換為 GGML 格式存至 `Models/ggml-model.bin`。

### 3. 建置並執行

```bash
swift build
swift run
```

或以 Xcode 開啟：

```bash
open Package.swift
```

在 Xcode 中按 Cmd+R 建置並執行。

### 4. 建置發行版 app bundle（選用）

```bash
bash Scripts/build_release.sh
```

此指令會建置最佳化的發行版執行檔、產生正確的 `.icns` 圖示，並封裝為含 Info.plist 的 `WhisperASR.app`。安裝方式：

```bash
cp -r WhisperASR.app /Applications/
```

若 macOS 顯示「無法開啟」警告（因為 app 未經簽署），請將以下指令中的路徑替換為 `WhisperASR.app` 的實際位置後執行：

```bash
xattr -cr /path/to/WhisperASR.app
```

## 使用方式

1. **新增檔案** — 將音訊／影片檔案拖至側邊欄，或點擊 **+** 按鈕
2. **錄製應用程式音訊** — 點擊錄音按鈕，選擇執行中的應用程式後開始錄音；最近使用的應用程式會排在最前面
3. **即時轉錄與翻譯** — 在錄音對話框中啟用即時轉錄，錄音時即可看到文字；在設定中設定目標語言，可在每段下方看到即時翻譯
4. **等待轉錄** — 檔案會排入佇列，依序轉錄並顯示進度與預估剩餘時間
5. **檢視** — 點擊已完成項目，查看含時間戳記的逐字稿
6. **翻譯** — 點擊翻譯按鈕，將完成的逐字稿翻譯成任何設定語言
7. **搜尋** — 使用側邊欄搜尋列篩選所有檔案，或按 Cmd+F 在逐字稿中搜尋
8. **播放音訊** — 使用底部播放器控制；文字會同步高亮顯示
9. **匯出** — 點擊右上角匯出按鈕，儲存為 SRT 或純文字格式

### 設定

開啟**設定**（Cmd+,）進行設定：

- **目標語言** — 選擇翻譯的目標語言
- **語音語言** — 使用自動偵測，或針對普通話、英文及中英混合語音引導目前選取的模型
- **OpenAI 翻譯 API** — 只需填入 API 金鑰；端點預設為 OpenAI，模型預設為 `gpt-4o-mini`。支援任何 OpenAI 相容端點（包括本地模型）。
- **語音辨識模型** — 下載、選擇或刪除模型；轉錄會使用選取的模型
- **自訂模型** — 可選的自訂 `ggml-*.bin` 模型檔案路徑，僅在未選取下載模型時使用

## 專案結構

```
Sources/
├── WhisperASRApp.swift        # 應用程式進入點
├── ContentView.swift          # NavigationSplitView 版面配置
├── SidebarView.swift          # 檔案清單，支援拖放與右鍵選單
├── DetailView.swift           # 逐字稿顯示、進度、匯出
├── PlayerView.swift           # 音訊播放控制
├── RecordingView.swift        # 應用程式音訊錄製 UI
├── AudioRecorder.swift        # ScreenCaptureKit 音訊擷取
├── AppState.swift             # 應用程式狀態管理與轉錄佇列
├── Models.swift               # 資料模型
├── TranscriptionService.swift # whisper.cpp C API 整合
├── TranslationService.swift   # OpenAI 相容翻譯 API
├── TranscriptionStore.swift   # JSON 逐項持久化儲存
├── AudioLoader.swift          # AVAssetReader 音訊載入
├── AudioPlayerManager.swift   # AVPlayer 封裝
├── AppIconGenerator.swift     # 程式化應用程式圖示產生
└── SettingsView.swift         # 語言、翻譯與模型設定
Scripts/
├── build_whisper_lib.sh       # 建置 whisper.cpp xcframework
├── convert_model.sh           # 將 HuggingFace 模型轉換為 GGML
└── build_release.sh           # 建置含圖示的發行版 .app bundle
Frameworks/
└── CWhisper.xcframework/      # 預先建置的 whisper.cpp 靜態函式庫
```

## 授權

本專案使用 [whisper.cpp](https://github.com/ggml-org/whisper.cpp)（MIT 授權）及聯發科技研究院的 [Breeze-ASR-25](https://github.com/mtkresearch/Breeze-ASR-25) 模型。
