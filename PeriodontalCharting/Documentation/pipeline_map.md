# Periodontal Charting — Pipeline Map

A navigation aid, not a replacement for the deep-dive guides. Read this first to
understand **which of the three greater pipelines a file belongs to and what it
talks to**, then jump into [system_guide.md](system_guide.md) /
[frontend_guide.md](frontend_guide.md) / [ml_tokenizer_guide.md](ml_tokenizer_guide.md)
for the internals of any one box.

> [!NOTE]
> This file documents the **3D visualization pipeline** and the **SwiftData
> persistence layer** in full — neither is covered anywhere else in
> `Documentation/`. `project_guide.md`'s roadmap still lists "Patient
> persistence" as *Pending*; it is actually implemented (`PatientChart.swift`,
> §4 below) and that roadmap entry is stale.

---

## Table of Contents

1. [The Big Picture](#1-the-big-picture)
2. [Pipeline A — Voice → Chart Mutation (NLP)](#2-pipeline-a--voice--chart-mutation-nlp)
3. [Pipeline B — Chart State → 2D Rendering](#3-pipeline-b--chart-state--2d-rendering)
4. [Pipeline C — Chart State → 3D Rendering + Persistence](#4-pipeline-c--chart-state--3d-rendering--persistence)
5. [The One Shared Thing: `mouth: [Int: ToothObject]`](#5-the-one-shared-thing-mouth-int-toothobject)
6. [Cross-Pipeline Glue Files](#6-cross-pipeline-glue-files)
7. [Where To Add a New Feature](#7-where-to-add-a-new-feature)
8. [Quick File Finder](#8-quick-file-finder)

---

## 1. The Big Picture

Everything in this app ultimately produces or consumes one value:
**`mouth: [Int: ToothObject]`** — a dictionary keyed by FDI tooth number, owned
by `ChartDashboard`. The three pipelines are three independent *routes* to
read or write that dictionary. They don't call each other directly — they
only meet at `mouth`.

```
                         ┌─────────────────────────────┐
                         │   ChartDashboard.mouth       │
                         │   [Int: ToothObject]         │  <- single source of truth
                         └───────────────┬───────────────┘
              writes ▲                  │ reads                    reads ▲
                      │                  ▼                                │
   ┌──────────────────┴──────┐   ┌───────────────┐            ┌──────────┴────────────┐
   │  PIPELINE A               │  │  (same object) │            │  PIPELINE C            │
   │  Voice → NLP → Command    │  │                │            │  3D RealityKit view    │
   │  (mic/text in, mutations  │  └───────┬───────┘            │  + SwiftData persist   │
   │  out)                     │          │                     │  (PatientChart)        │
   └──────────────────────────┘          ▼                     └────────────────────────┘
                                  ┌───────────────┐
                                  │  PIPELINE B    │
                                  │  2-D chart grid│
                                  │  (SwiftUI)     │
                                  └───────────────┘
```

- **Pipeline A (Voice/NLP)** — turns microphone audio or a typed/simulated
  transcript into `AnnotationCommand`s and applies them to `mouth` via
  `ChartProcessor`. This is the pipeline `system_guide.md` documents in full.
- **Pipeline B (2D chart)** — renders `mouth` as the WHO-standard grid of 32
  tooth columns. Also the *only* pipeline that lets a clinician hand-edit a
  single cell (tap → `NumberPadPopoverView`). Documented in
  `frontend_guide.md` §3.2–3.4.
- **Pipeline C (3D + persistence)** — renders the same `mouth` as a RealityKit
  3-D dentition (`3D/` folder) and is also where `mouth` gets saved to/loaded
  from disk via SwiftData (`PatientChart`). **Not documented elsewhere** — see
  §4 below.

All three run inside the same `ChartDashboard` view instance and share the
exact same `@State private var mouth`. There is no cross-pipeline API beyond
"pass `mouth` in, get commands/edits back out."

---

## 2. Pipeline A — Voice → Chart Mutation (NLP)

**Full spec:** [system_guide.md](system_guide.md) (tokenization, parser state
machine, targeting modes, worked examples). This section is only the map.

```
Mic audio ──▶ Audio/ (speaker isolation + WhisperKit STT) ──▶ text
   text ──▶ NLP/Tokenizer/ (TokenizerManager: ML or rule-based) ──▶ [VoiceToken]
   tokens ──▶ NLP/Parser/VoiceCommandParser ──▶ [AnnotationCommand]
   commands ──▶ Models/ChartProcessor.apply(command:to:) ──▶ mutates mouth
```

| Stage | Owner file(s) | Entry point |
|---|---|---|
| Recording / speaker isolation | `Audio/AudioManager.swift`, `Audio/SpeakerGate*.swift`, `Audio/TSE/*` | consumed internally by `TranscriptionEngine` |
| Speech-to-text | `Audio/TranscriptionEngine.swift`, `Audio/SileroVADEngine.swift` | `ViewModels/TranscriptionViewModel.swift` |
| Tokenization | `NLP/Tokenizer/TokenizerManager.swift` (+ `MLVoiceTokenizer`/`VoiceTokenizer` beneath it) | `TokenizerManager.shared.tokenize(text:isFinal:)` |
| Parsing | `NLP/Parser/VoiceCommandParser*.swift` | `VoiceCommandParser(configuration:).parse(text:isFinal:)` |
| Application | `Models/ChartProcessor.swift` | `ChartProcessor.apply(command:to:)` (static, headless) |
| Orchestration | `ViewModels/AIVoiceViewModel.swift` | owns `commandHistory`, wires everything above together, feeds `ChartDashboard` |
| UI surface | `Views/Voice/AIListeningView.swift`, `Views/Chart/ChartDashboard.swift` (AI Mode panel) | user-facing |
| Config that steers the parser | `Configuration/ChartingConfiguration.swift`, `Configuration/ChartingCursor.swift` (set in `Views/Onboarding/OnboardingView.swift`) | consumed by `VoiceCommandParser` |

**Where it plugs into `mouth`:** `ChartDashboard.recomputeChart()` (called on
`aiViewModel.commandHistory`/`committedCommands` change) rebuilds `mouth` from
`ToothObject.fullMouthEmpty()` by replaying every `AnnotationCommand` through
`ChartProcessor.apply`. It never mutates `mouth` cell-by-cell — the whole
dictionary is thrown away and rebuilt on every voice update, which is what
guarantees determinism (see `system_guide.md` §15).

**Debug/offline route (bypasses the mic entirely):** `Debug/SelectionDebugMenu.swift`
→ `AIVoiceViewModel.parseInstant(text:)` → same tokenizer/parser/processor
chain, `isFinal: true` in one shot. This is also what the CLI regression
runner (`test_parser.sh` / `run_regression_tests.swift`) uses headlessly via
`Debug/ChartTestingUtilities.swift`.

---

## 3. Pipeline B — Chart State → 2D Rendering

**Full spec:** [frontend_guide.md](frontend_guide.md) §2–3.2–3.4 (component
hierarchy, cell types, path-drawing math). Map only, here:

```
mouth ──▶ ChartDashboard ──▶ ChartContentView (Equatable) ──▶ QuadrantView × 4
                                                                   └─▶ ToothColumnView × 8
                                                                          ├─ sharedGrid   (Implant, Mobility)
                                                                          ├─ aspectGrid   (GM/PD/CAL/Bleeding/Plaque)
                                                                          └─ toothGraphic (ToothGraphicSideView × 2)
```

- **Read path:** every sub-view is a pure function of `mouth[toothNumber]` —
  no view in this pipeline mutates state on its own except through explicit
  taps.
- **Write path (manual edit):** tap a numeric cell → `ToothColumnView`
  presents `NumberPadPopoverView` → on commit, calls `updateTooth(_:)` on
  `ChartDashboard`, which does `mouth[tooth.toothNumber] = tooth` directly
  (no `ChartProcessor` involved — that's Pipeline A's mechanism only).
- **Highlight overlay:** `ChartSelectionModel` (`@EnvironmentObject`) is fed
  by Pipeline A's cursor/selection (`aiViewModel.currentCursor` /
  `activeSelection`) via `ChartDashboard.updateHighlight()`. It's how the
  voice pipeline visually "points" at the cell it's about to fill, even
  though Pipeline B itself has no idea a voice pipeline exists.

**Ownership boundary:** `Models/ChartProcessor.swift` is the only file shared
*by name* between Pipeline A and Pipeline B's data model — but Pipeline B
never calls it directly; it just reads whatever `mouth` currently is,
regardless of who wrote it last.

---

## 4. Pipeline C — Chart State → 3D Rendering + Persistence

**Not documented elsewhere — this is the primary net-new content of this
file.** Two logically separate jobs share the `3D/` + `Models/PatientChart.swift`
files: rendering the 3-D dentition, and saving/loading a chart to disk.

### 4a. 3-D rendering (`3D/` folder, RealityKit)

```
mouth ──▶ PeriodontalAnatomyPresenter ──▶ PeriodontalSceneView
                                              ├─ ToothMeshLoader.load()         (once — static mesh + FDI identity)
                                              ├─ GingivalAnatomyGenerator.build (procedural gum + bone, driven by mouth)
                                              └─ DentalArch                     (FDI ↔ arch/quadrant lookup, shared ordering with Pipeline B)
```

| File | Responsibility |
|---|---|
| `3D/PeriodontalSceneView.swift` | RealityKit `View`. Orbit/pinch/tap gestures, camera, per-tooth selection highlight (glowing shell — never mutates the tooth's own material), arch filter (Both/Upper/Lower), gum opacity slider. Also defines `PeriodontalAnatomyPresenter`, the `NavigationStack` wrapper `ChartDashboard` presents as a `.fullScreenCover`, and `healthyControl()`, an extension that produces an idealised disease-free copy of `mouth` for side-by-side comparison. |
| `3D/ToothMeshLoader.swift` | Loads `baked_teeth.usdc` (bundled static asset) once. Because the mesh's own names are unreliable, tooth identity is derived by **position around the arch**, not by asset metadata (if teeth ever look mirrored/misidentified, check the arch-position derivation here first, and flip handedness as needed). Purely geometric — has zero dependency on `ToothObject`/`mouth`. Produces `LoadedTeeth` (FDI → mesh entity, centroid, vertices, CEJ height). |
| `3D/DentalArch.swift` | Tiny enum: FDI tooth order per arch (maxilla/mandible), identical ordering to the 2-D chart's quadrant arrays in `ChartDashboard`/`ChartContentView` — this is what lets `GingivalAnatomyGenerator` reuse `AspectData` site index (0/1/2) directly as "previous/mid/next tooth" without a separate lookup. |
| `3D/GingivalAnatomyGenerator.swift` | Procedurally builds gum + alveolar bone meshes **from the same `mouth` dictionary Pipeline B reads** (uses `probingDepth`/`gingivalMargin`/`missing` per tooth to sculpt tissue height/recession per site). This is the file that makes the 3-D view "the exact same data, different projection" rather than an independent visualization. |
| `3D/ToothStatusPanel.swift` | Small side-panel view showing a tapped tooth's chart values (PD/GM/mobility/etc.) — reads directly from `mouth[fdi]`, same cells Pipeline B renders, just laid out differently. |

**Entry point from the rest of the app:** `ChartDashboard`'s `view.3d` toolbar
button sets `show3DView = true`, which triggers
`.fullScreenCover { PeriodontalAnatomyPresenter(mouth: mouth) }`
([ChartDashboard.swift:238](../Views/Chart/ChartDashboard.swift)). It is a
**read-only snapshot** — `mouth` is passed by value; edits made in 3-D (tooth
selection only, no numeric editing exists in 3-D yet) do not write back.

### 4b. Persistence (`Models/PatientChart.swift`, SwiftData)

```
PeriodontalChartingApp ──▶ .modelContainer(for: PatientChart.self)   (app-wide SwiftData store)
ContentView ──▶ @Query(sort: \PatientChart.updatedAt) ──▶ patient list sidebar
             ──▶ selectedChart: PatientChart? ──▶ ChartDashboard(chart: selectedChart)
ChartDashboard.onAppear ──▶ loadChart(): mouth = chart.mouth
ChartDashboard "Save" action ──▶ saveChart(): chart.mouth = mouth; modelContext.save()
```

| File | Responsibility |
|---|---|
| `App/PeriodontalChartingApp.swift` | Registers the SwiftData container for `PatientChart` once at the app root, injected into the environment for `@Query`/`modelContext` everywhere below it. |
| `App/ContentView.swift` | Sidebar: lists all `PatientChart` records (`@Query`), "New Chart" creates + inserts one, swipe-to-delete removes one, selecting a row sets `selectedChart` which is handed to `ChartDashboard`. |
| `Models/PatientChart.swift` | The `@Model` class itself. Stores the *entire* mouth as one JSON blob (`teethData: Data`, `[ToothObject]` encoded) rather than a SwiftData relationship per tooth — deliberate: there's no need to query individual teeth, so a flat blob keeps the schema simple. `mouth` is a computed property that encodes/decodes transparently and bumps `updatedAt` on write. |
| `Views/Chart/ChartDashboard.swift` | `chart: PatientChart?` is passed in from `ContentView`. `loadChart()` copies `chart.mouth` into the local `@State mouth` on `.onAppear`. `saveChart()` writes `mouth` back onto `chart.mouth` and calls `modelContext.save()` — this is a manual/explicit save, **not** autosave; `mouth` can diverge from the persisted `chart.mouth` until the user saves. |

**Important seam:** Pipelines A and B mutate the *in-memory* `mouth` freely
and continuously (every voice command, every tap). Nothing is written to
`PatientChart`/disk until `ChartDashboard.saveChart()` is explicitly invoked.
If you're chasing a bug where "the chart looks right on screen but reopening
the patient loses the change," start here — it's almost certainly a missing
save call, not a Pipeline A/B bug.

---

## 5. The One Shared Thing: `mouth: [Int: ToothObject]`

Every pipeline treats this dictionary as the single contract between them.
Defined in `Models/Models.swift`. If you're trying to figure out "does
feature X touch pipeline Y," the fastest test is: **does the file read or
write `mouth`, `ToothObject`, or `AnnotationCommand`?** If yes, it's part of
the picture above; if no, it's UI chrome local to one pipeline (onboarding
copy, toolbar icons, debug menu labels, etc.) and doesn't cross pipelines.

| Type | Defined in | Read by | Written by |
|---|---|---|---|
| `ToothObject` / `mouth: [Int: ToothObject]` | `Models/Models.swift` | Pipelines B & C (rendering), `PatientChart.mouth` (persistence) | Pipeline A via `ChartProcessor.apply`; Pipeline B via direct tap-edit (`updateTooth`); Pipeline C never writes it (read-only 3-D view) |
| `AnnotationCommand` | `Models/Models.swift` | `ChartProcessor.apply`, `AIVoiceViewModel.commandHistory` (for the ghosted-preview diff in Pipeline B) | `NLP/Parser/VoiceCommandParser*` only |
| `PatientChart` | `Models/PatientChart.swift` | `ContentView` (sidebar list), `ChartDashboard.loadChart()` | `ContentView.addChart()`, `ChartDashboard.saveChart()` |

---

## 6. Cross-Pipeline Glue Files

These are the handful of files that *aren't* inside any one pipeline's folder
but exist purely to connect two of them — worth knowing so you don't go
looking for "the voice code" inside `Views/Chart/` and get confused:

| File | Connects | What it does |
|---|---|---|
| `Views/Chart/ChartDashboard.swift` | A + B + C | The literal meeting point. Owns `mouth`, hosts the AI panel (A), the tooth grid (B), and the `.fullScreenCover` 3-D presenter + save/load (C). |
| `ViewModels/AIVoiceViewModel.swift` | A → B | Bridges the headless NLP pipeline into `@Published` state that SwiftUI (B) observes (`commandHistory`, `currentCursor`, ghosting via `committedCommands`). |
| `Configuration/ChartingConfiguration.swift` + `ChartingCursor.swift` | Onboarding UI → A | User-configured traversal order (set in `Views/Onboarding/`) steers how the parser advances through teeth — the only place user *preferences* (not chart data) cross into Pipeline A. |
| `3D/DentalArch.swift` | B ↔ C | Guarantees the FDI ordering used by the 2-D quadrant arrays and the 3-D anatomy generator's site-index math stay in lock-step. If you ever reorder quadrants in `ChartContentView`, this file (and `GingivalAnatomyGenerator`) is the other place that assumption lives. |

---

## 7. Where To Add a New Feature

Use this as a quick routing table when you're not sure which pipeline (and
which guide) a new feature belongs to:

| You want to... | Primary pipeline | Start reading |
|---|---|---|
| Add a new voice command / metric / clinical shorthand | A | [system_guide.md](system_guide.md) §3–4, `NLP/Parser/VoiceCommandParser+Parse.swift` |
| Change how a cell looks/is laid out in the grid | B | [frontend_guide.md](frontend_guide.md) §3.2, `Views/Chart/ToothRowViews.swift` |
| Add a manual-edit interaction (new popover, new gesture) | B | `Views/Chart/ToothColumnView.swift`, `NumberPadPopoverView.swift` |
| Change 3-D tooth/gum appearance or add a new visualization mode | C (3D) | §4a above, `3D/GingivalAnatomyGenerator.swift` |
| Add a field to what's saved per patient, or add multi-exam history | C (persistence) | §4b above, `Models/PatientChart.swift` |
| Change STT accuracy / vocabulary bias / speaker isolation | A (upstream) | `Audio/Domain/ClinicalConfig.swift`, `Audio/TranscriptionEngine.swift` — see also [[stt-priority-accuracy]] |
| Change ML tokenizer behavior specifically | A | [ml_tokenizer_guide.md](ml_tokenizer_guide.md) |

---

## 8. Quick File Finder

```
Pipeline A (Voice/NLP)         Pipeline B (2D Chart)              Pipeline C (3D + Persistence)
────────────────────────       ────────────────────────           ─────────────────────────────
Audio/                         Views/Chart/ChartDashboard.swift   3D/PeriodontalSceneView.swift
NLP/                           Views/Chart/QuadrantView.swift     3D/ToothMeshLoader.swift
ViewModels/AIVoiceViewModel    Views/Chart/ToothColumnView.swift  3D/DentalArch.swift
Views/Voice/                   Views/Chart/ToothRowViews.swift    3D/GingivalAnatomyGenerator.swift
Configuration/                 Views/Chart/ToothGraphicSideView   3D/ToothStatusPanel.swift
Testing/, Debug/*Utilities     Views/Chart/NumberPadPopoverView   Models/PatientChart.swift
                                                                   App/ContentView.swift (@Query)

Shared by all three: Models/Models.swift, Models/ChartProcessor.swift, App/PeriodontalChartingApp.swift
```
