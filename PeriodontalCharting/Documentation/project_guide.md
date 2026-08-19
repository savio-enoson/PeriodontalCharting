# Periodontal Charting — Project Guide

A comprehensive, iPad-optimised SwiftUI application for dental professionals to efficiently record and track periodontal disease clinical parameters using real-time voice commands.

---

## Documentation

| Guide | Contents |
|---|---|
| **[project_guide.md](project_guide.md)** *(this file)* | Project brief, design principles, getting started, color semantics, roadmap |
| **[frontend_guide.md](frontend_guide.md)** | Project structure, architecture, Swift file-by-file reference |
| **[system_guide.md](system_guide.md)** | NLP pipeline, tokenization, `StatefulParser` design, command inference, annotation logic |
| **[STT_documentation.md](STT_documentation.md)** | Speech-to-text layer: Wav2Vec2 (Indonesian FP16) pipeline, audio capture, CTC decoding |
| **[pipeline_map.md](pipeline_map.md)** | Map of the three main pipelines and cross-pipeline data flow |
| **[TSE_documentation.md](TSE_documentation.md)** | Target Speech Extraction (TSE) architecture and source separation |

---

## Table of Contents

1. [Project Brief](#1-project-brief)
2. [Key Design Principles](#2-key-design-principles)
3. [Getting Started](#3-getting-started)
4. [Color Semantics](#4-color-semantics)
5. [Roadmap](#5-roadmap)

---

## 1. Project Brief

Periodontal charting is historically a highly manual process. A practitioner must simultaneously hold clinical instruments and dictate 3–6 numeric measurements per tooth site to an assistant who enters data — a process prone to transcription errors and inefficiency.

This project modernises the workflow across three layers:

1. **Chart rendering (Complete):** A WHO-standard, visually dense clinical chart that renders a full 32-tooth mouth across four quadrants. The chart scales seamlessly on iPad, supporting pinch-to-zoom and a 1-column vs 2-column layout toggle.

2. **Voice annotation pipeline (Complete):** A real-time voice-transcription pipeline that converts clinical dictation in **Indonesian** (e.g., *"gigi 16 tiga empat lima tiga empat tiga"*) into structured `AnnotationCommand` mutations, enabling completely hands-free charting. Wav2Vec2 (Indonesian FP16) provides on-device speech-to-text via constrained CTC decoding with a prefix Trie; a rule-based `VoiceTokenizer` and a stateful session parser (`StatefulParser`) convert confirmed transcription chunks into chart mutations. The NLP engine handles complex clinical ranges, missing teeth, dynamic highlighting, and sequence traversals based on custom clinician configurations.

3. **Speaker isolation (handled by a separate peer module):** A speaker verification and source separation layer that prevents assistant voices or ambient speech from reaching the chart. See `Audio/` for the relevant components.

---

## 2. Key Design Principles

- **Clinical accuracy over aesthetics:** Every rendering decision (line direction, GM sign convention, mirroring logic) follows WHO and standard periodontal charting conventions.

- **Visually dense:** The chart fits all 32 teeth with full data grids on a single iPad screen, favouring legibility of numbers over whitespace.

- **Native SwiftUI:** No third-party design system dependency. All styling uses semantic SwiftUI colors and adaptive system fonts so Dark Mode, Dynamic Type, and accessibility work out of the box.

- **Indonesian-first NLP:** The voice pipeline is designed for Indonesian clinical dictation, recognising both written digits (`"3"`) and spoken Indonesian words (`"tiga"`), as well as clinical shorthand (`"gak ada"` = missing, `"lanjut"` = advance to next, `"BOP"` = bleeding on probing).

- **Deterministic replay:** The chart is rebuilt from scratch by replaying the full command history on every change. There is no mutable chart state — only an append-only log of `AnnotationCommand` values. This guarantees that re-parsing the same transcript always produces the same chart, regardless of mid-stream partial parses during live streaming.

- **Incremental session parser:** `StatefulParser` persists across audio chunk boundaries for the duration of a dictation session. Cursor position, active selection, and pending numbers carry forward between chunks. `isFinal: true` marks the end of the **entire session**, triggering a forced flush of all buffered state. For regression tests and simulation, a fresh `StatefulParser` is constructed and fed the complete transcript at once — the "incremental" aspect is transparent to batch callers.

- **Ghosted preview:** During live dictation, the chart renders a two-tier display: *preview commands* (derived from the full running transcript including unconfirmed hypotheses) shown in full color, and *committed commands* (derived from CTC-confirmed chunks only) marked as finalised. This keeps the chart maximally responsive while clearly communicating certainty.

---

## 3. Getting Started

### Requirements

- macOS 14+ with Xcode 16+
- Target: **iPad** simulator or physical iPad (layout specifically tailored for iPad — iPhone not supported)
- The `Wav2Vec2_Indonesian_FP16.mlmodelc` model is bundled directly in the app (no download required).

### Steps

1. Open `PeriodontalCharting.xcodeproj` in Xcode 16+.
2. Select an iPad simulator destination (iPad Pro 12.9" recommended).
3. Build and run (`Cmd + R`).
4. **First launch:** The onboarding screen appears. Record a voice calibration sample and configure your preferred annotation traversal order, then tap **Complete Setup**.
5. The chart opens with all teeth empty (`fullMouthEmpty()`). Use the **Debug** (ladybug) toolbar button to apply test highlights, adjust simulation WPM, or instantly fill the chart from a test transcript.
6. Tap **AI Mode** to open the voice panel. Tap **▶** to run the simulation with the selected test transcript, or tap **Mic** to begin live on-device dictation.
7. Toggle layout mode via the toolbar (1-col / 2-col).
8. Pinch-to-zoom to inspect fine detail; use the zoom slider (bottom-right) to return to 1×.
9. Tap **Settings** (gear icon) to reconfigure traversal order or re-record the voice calibration sample.

### Test Data

Use the **Debug** (ladybug) toolbar button to open `SelectionDebugMenu`. Choose any transcript from the **Instant Fill** picker and tap **Fill Chart** to populate all teeth immediately using `parseInstant`. Alternatively, tap **AI Mode → ▶** to stream the selected transcript word-by-word at the configured WPM.

Pre-built highlight scenarios (single cell, Q1 row, all implants) are available in the Debug menu without invoking the voice pipeline at all.

---

## 4. Color Semantics

All colors are system-adaptive — no manual Dark Mode handling is required. The app uses SwiftUI semantic colors throughout.

| Usage | Color |
|---|---|
| Cell backgrounds | `Color(.systemBackground)` |
| Grid hairlines & borders | `Color(.separator)` |
| Hatched pattern base | `Color(.tertiarySystemBackground)` |
| Missing tooth graphic | `Color(.tertiarySystemBackground)` |
| Normal tooth tint | `Color.blue.opacity(0.1)` |
| Gingival Margin line | `.red` |
| Bleeding dots | `.red` |
| Probing Depth ≥ 4mm | `.red` (in `TripleValueRow`) |
| Probing Depth line | `.blue` |
| Plaque dots + Implant icon | `.blue` |
| Active selection highlight | `Color.orange` (2pt `strokeBorder`) |
| Toolbar / nav chrome | `Color(red: 0.05, green: 0.2, blue: 0.5)` (dark navy) |
| AI panel border | Orange-to-deep-orange `LinearGradient` |

> [!NOTE]
> PD values ≥ 4 mm rendering in red is a clinical decision — this threshold indicates the presence of a periodontal pocket requiring clinical attention per standard periodontal indices.

---

## 5. Roadmap

### Completed

- [x] **Full-mouth chart rendering** — all 32 teeth, 4 quadrants, WHO-standard layout.
- [x] **Custom Path rendering** — continuous GM and PD lines with inter-tooth blending and mirroring.
- [x] **Furcation modelling** — per-tooth anatomical provisioning with hatched fallback.
- [x] **Zoom Control** — custom dynamic vertical zoom slider instead of standard pinch-to-zoom for better one-handed usability; full `MagnificationGesture` support still available.
- [x] **Native SwiftUI** — all views use semantic system colors and adaptive system fonts. Fully supports iOS 17+, Swift 6 strict concurrency (zero warnings), Dark Mode, and Dynamic Type out of the box.
- [x] **Navigation style** — `NavigationSplitView` with navy chrome, custom floating toolbars, adaptive sidebar toggle.
- [x] **Onboarding & Configuration** — `OnboardingView` with audio calibration, live anatomical visualiser, and drag-and-drop traversal config.
- [x] **State Machine** — Indonesian NLP engine (`VoiceTokenizer` + `StatefulParser`) parses confirmed chunks into `AnnotationCommand` mutations with range support, verbal numbers, and sub-site targeting. `StatefulParser` persists across chunk boundaries within a session.
- [x] **Dynamic UI Camera & Highlighting** — dual-state highlight mask (cursor vs active selection) with `ScrollViewProxy` auto-pan and padded frame limits for free panning in AI Mode.
- [x] **Selection Debug Menu** — developer sheet with WPM slider, transcript picker, instant fill, regression testing buttons, and pre-built highlight scenarios.
- [x] **Regression Testing** — `ChartProcessor` + `ChartTestingUtilities` + CLI `test_parser.sh` for headless parser validation against JSON ground truth files. In-app "Save as Ground Truth" / "Test vs Ground Truth" buttons in the debug menu.
- [x] **Manual editing** — tap any numeric cell to open a `NumberPadPopoverView` (full-screen cover); tap furcation cells to cycle value directly; tap implant cell to toggle.
- [x] **Expanded test suite** — full dictation scripts `dr_lucky_ground.txt`, `student_ground.txt` with paired ground truth JSONs in `Testing/Raw/` and `Testing/Ground/`.
- [x] **Live speech-to-text integration** — `Wav2VecEngine` + `Wav2VecViewModel` fully integrated. `AIVoiceViewModel` wires confirmed and live-preview chunks to the annotation parser. Chart renders a ghosted-preview + committed-solid two-tier display during live dictation.
- [x] **Patient persistence** — SwiftData layer (`PatientChart.swift`) integrated for saving and loading charting sessions per patient.
- [x] **Speaker isolation pipeline** — ECAPA-TDNN and BSRNN integrated in `Audio/` subdirectories for target speech extraction.

### Pending

- [ ] **Speaker isolation validation** — end-to-end device validation of TSE-gated charting sessions (enrollment → live rejection → chart accuracy) is pending.
- [ ] **PDF export** — generate a PDF clinical report from the live chart state (toolbar button present, action not yet implemented).
- [ ] **iPhone / compact layout** — responsive layout fallback for smaller screens.
