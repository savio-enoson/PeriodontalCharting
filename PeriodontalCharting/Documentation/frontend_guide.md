# Periodontal Charting — Frontend & Architecture Guide

This guide covers the project structure, component architecture, and Swift file-by-file reference for the Periodontal Charting app.

For the project brief and getting started instructions, see [project_guide.md](project_guide.md).
For the NLP command inference system, see [system_guide.md](system_guide.md).
For the STT pipeline, see [STT_documentation.md](STT_documentation.md).
For the TSE system, see [TSE_documentation.md](TSE_documentation.md).

---

## Table of Contents

1. [Project Structure](#1-project-structure)
2. [Architecture](#2-architecture)
3. [File-by-File Reference](#3-file-by-file-reference)
   - [App/](#31-app)
   - [Views/Chart/](#32-viewschart)
   - [Views/Voice/](#33-viewsvoice)
   - [Views/Onboarding/](#34-viewsonboarding)
   - [ViewModels/](#35-viewmodels)
   - [Debug/](#36-debug)
   - [Models/](#37-models)
   - [Configuration/](#38-configuration)
   - [Audio/](#39-audio)
   - [NLP/](#310-nlp-overview)
   - [Testing/](#311-testing)
   - [AI/ (Model Bundles)](#312-ai-model-bundles)
   - [3D/](#313-3d)
4. [Performance Architecture](#4-performance-architecture)

---

## 1. Project Structure

```
PeriodontalCharting/
├── PeriodontalCharting.xcodeproj/
└── PeriodontalCharting/
    ├── App/
    │   ├── PeriodontalChartingApp.swift  ← @main + SwiftData modelContainer
    │   ├── ContentView.swift             ← onboarding gate + NavigationSplitView + @Query patient list
    │   └── ModelLoadingSplash.swift      ← shown while Wav2Vec model loads
    ├── Models/
    │   ├── Models.swift
    │   ├── ChartProcessor.swift
    │   └── PatientChart.swift            ← @Model, SwiftData persistence
    ├── NLP/
    │   ├── Models/
    │   │   └── VoiceToken.swift
    │   ├── Tokenizer/
    │   │   ├── TokenizerManager.swift
    │   │   ├── VoiceTokenizer.swift
    │   │   ├── VoiceTokenizer+Helpers.swift
    │   │   └── VoiceTokenizer+Parsing.swift
    │   └── Parser/
    │       ├── StatefulParser.swift
    │       ├── StatefulParser+Flush.swift
    │       └── StatefulParser+Lookahead.swift
    ├── Configuration/
    │   ├── ChartingConfiguration.swift
    │   ├── ChartingCursor.swift
    │   └── ToothFramePreferenceKey.swift
    ├── Audio/
    │   ├── AppLog.swift
    │   ├── Capture/
    │   │   └── AudioManager.swift        ← calibration recording/playback
    │   ├── Profiles/
    │   │   ├── CalibrationTake.swift
    │   │   ├── VoiceProfile.swift
    │   │   └── VoiceProfileStore.swift
    │   ├── Signal/
    │   │   ├── AutoGain.swift            ← adaptive gain, ~1.5s time constant
    │   │   └── HighPassFilter.swift      ← 80 Hz IIR biquad high-pass
    │   ├── Speaker/
    │   │   ├── SpeakerGate.swift
    │   │   ├── SpeakerGateService.swift
    │   │   └── SpeakerVerdict.swift      ← deprecated, entire file commented out
    │   ├── TSE/
    │   │   ├── TSEConfig.swift
    │   │   ├── TSEEngine.swift
    │   │   ├── TSEExtractor.swift
    │   │   ├── TSEFeatures.swift
    │   │   └── TSERescue.swift
    │   ├── Transcription/
    │   │   └── TranscriptionEngine.swift ← thin singleton; provides makeSpeakerGateIfNeeded()
    │   └── Wav2Vec/
    │       ├── CTCDecoder.swift          ← constrained CTC beam search
    │       ├── PrefixTrie.swift          ← clinical vocabulary prefix trie
    │       ├── Wav2VecAudioCapture.swift ← AVFoundation mic + 16kHz resampling + signal conditioning
    │       ├── Wav2VecEngine.swift       ← CoreML inference wrapper (Wav2Vec2_Indonesian_FP16)
    │       └── Wav2VecViewModel.swift    ← live pipeline orchestrator
    ├── ViewModels/
    │   └── AIVoiceViewModel.swift
    ├── Views/
    │   ├── Chart/
    │   │   ├── ChartAssetStore.swift
    │   │   ├── ChartDashboard.swift
    │   │   ├── NumberPadPopoverView.swift
    │   │   ├── QuadrantView.swift
    │   │   ├── ToothColumnView.swift
    │   │   ├── ToothGraphicSideView.swift
    │   │   ├── ToothRowViews.swift
    │   │   └── ZoomableScrollView.swift
    │   ├── Voice/
    │   │   └── AIListeningView.swift
    │   └── Onboarding/
    │       ├── AnnotationVisualizerView.swift
    │       ├── OnboardingView.swift
    │       └── TwoItemReorderable.swift
    ├── Debug/
    │   ├── ChartTestingUtilities.swift
    │   ├── SelectionDebugMenu.swift
    │   ├── SessionRecorder.swift         ← debug: records raw+gated audio per session
    │   └── SpeakerGateDebugView.swift
    ├── Testing/
    │   ├── TestTranscripts.swift
    │   ├── Raw/
    │   │   ├── dr_lucky_audio.m4a
    │   │   ├── dr_gaby_audio.m4a
    │   │   ├── student_audio.m4a
    │   │   ├── dr_lucky_ground.txt
    │   │   └── student_ground.txt
    │   ├── Ground/
    │   │   ├── ground_truth.json         ← ground truth for dr_lucky
    │   │   └── student_ground.json       ← ground truth for student
    │   └── Suite/
    │       ├── run_regression_tests.swift
    │       ├── build_tests.sh
    │       └── (other test utilities)
    ├── AI/                               ← gitignored
    │   ├── Target_Speech_Extraction/
    │   │   ├── SpeakerEmbedding_ECAPA.mlpackage
    │   │   ├── EnrollmentEncoder_WeSpeaker.mlpackage (TSE only, not the gate)
    │   │   ├── EnrollmentProjection_BSRNN.mlpackage
    │   │   ├── SpeakerConditioning_BSRNN.mlpackage
    │   │   ├── TSEFrontend_BSRNN.mlpackage
    │   │   ├── TSEMasker_BSRNN.mlpackage
    │   │   └── TargetSeparator_BSRNN.mlpackage
    │   └── Wav2Vec_STT/
    │       ├── Wav2Vec2_Indonesian_FP16.mlpackage
    │       ├── canonical_mapping.json
    │       ├── lexicon.txt
    │       └── vocab.json
    ├── 3D/
    │   ├── DentalArch.swift
    │   ├── GingivalAnatomyGenerator.swift
    │   ├── Model3DExporter.swift         ← exports chart state for 3D visualization
    │   ├── PeriodontalSceneView.swift
    │   ├── ToothMeshLoader.swift
    │   ├── ToothStatusPanel.swift
    │   └── baked_teeth.usdc
    ├── Documentation/
    │   ├── project_guide.md
    │   ├── frontend_guide.md              ← this file
    │   ├── system_guide.md
    │   ├── TSE_documentation.md
    │   ├── STT_documentation.md
    │   ├── pipeline_map.md
    │   └── analysis_results.md
    └── Assets.xcassets/
```

> [!NOTE]
> The `AI/` directory and all `.mlpackage`/`.mlmodelc` bundles are gitignored. A fresh clone has no bundled models.

---

## 2. Architecture

### Component Hierarchy

The application uses a modern, declarative SwiftUI component hierarchy. State flows top-down from the root `ChartDashboard` into individual `ToothColumnView` instances, which are read-only consumers of the `mouth` dictionary.

```
PeriodontalChartingApp
└── ContentView
    └── ChartDashboard          <- root state owner + toolbar
        └── ZoomableContainer   <- handles scale math + frame expansion
            └── ChartContentView (Equatable)  <- culled via .equatable()
                ├── QuadrantView (Q1 - Upper Right)
                │   ├── SideLabelsView
                │   └── ToothColumnView × 8
                │       ├── sharedGrid
                │       │   ├── ImplantCheckCell
                │       │   └── SingleValueCell    (Mobility)
                │       ├── aspectGrid (Facial / outer)
                │       │   ├── FurcationCell
                │       │   ├── TripleValueRow     (GM)
                │       │   ├── TripleValueRow     (PD)
                │       │   ├── TripleValueRow     (CAL, computed)
                │       │   ├── BoolDotRow         (Bleeding)
                │       │   └── BoolDotRow         (Plaque)
                │       ├── toothGraphic
                │       │   ├── ToothGraphicSideView (outer)
                │       │   └── ToothGraphicSideView (inner, mirrored)
                │       └── aspectGrid (Palatal / inner)
                ├── QuadrantView (Q2 - Upper Left)
                ├── QuadrantView (Q4 - Lower Right)
                └── QuadrantView (Q3 - Lower Left)
```

> [!NOTE]
> `ZoomableContainer` and `ChartContentView` are extracted structs that live in `ChartDashboard.swift`. `ZoomableContainer` owns the `baseSize` `GeometryReader` and `scaleEffect` math. `ChartContentView` conforms to `Equatable` and is the boundary for SwiftUI's `.equatable()` culling.

### State Flow

- **`ChartDashboard`** owns `mouth: [Int: ToothObject]` (the entire clinical record) and two `@StateObject`s: `ChartSelectionModel` (which cells are highlighted orange) and `AIVoiceViewModel` (the voice pipeline state).
- **`ChartSelectionModel`** is injected as an `@EnvironmentObject`, allowing `ToothColumnView` to read highlight state without prop-drilling. It relies entirely on the native `@Published` wrapper for invalidation, avoiding manual `objectWillChange.send()` calls that can cause double-publishing SwiftUI warnings.
- When `AIVoiceViewModel.commandHistory` changes, `ChartDashboard.onChange` rebuilds `mouth` from scratch by replaying all commands in order via `ChartProcessor.apply`. This ensures idempotency — replaying the full history always produces the same chart state regardless of mid-stream parsing artefacts.
- **`AIVoiceViewModel`** holds a reference to `Wav2VecViewModel` and sets its `onLiveTranscript` / `onConfirmedTranscript` hooks.
- During live dictation, `AIVoiceViewModel.committedCommands` is non-nil. `ChartDashboard` compares it against `commandHistory` to determine which cells are "committed" (solid) vs. "preview" (ghosted).
- **`ChartDashboard`** observes `aiViewModel.currentCursor` to keep the `ScrollViewProxy` camera in sync with the underlying parser tooth position. It deliberately does not listen to `activeSelection` changes directly during zoom operations to prevent jittery camera panning.

### FDI Quadrant Order

```
Q1: [18,17,16,15,14,13,12,11]  -- upper right
Q2: [21,22,23,24,25,26,27,28]  -- upper left
Q4: [48,47,46,45,44,43,42,41]  -- lower right (shown before Q3)
Q3: [31,32,33,34,35,36,37,38]  -- lower left
```

Q4 precedes Q3 to mirror the upper jaw layout and produce correct anatomical alignment in the 2-column view.

---

## 3. File-by-File Reference

### 3.1 `App/`

#### `App/PeriodontalChartingApp.swift`

The `@main` entry point. Registers the SwiftData `modelContainer` for `PatientChart` and provides the minimal `WindowGroup` wrapping `ContentView`.

---

#### `App/ContentView.swift`

Serves as both the **onboarding gate** and the root layout shell. Reads `@AppStorage("hasCompletedOnboarding")` and branches:

- **First launch (`hasCompletedOnboarding == false`):** Renders `OnboardingView` directly as a full-screen view, bypassing the `NavigationSplitView` entirely.
- **After onboarding (`hasCompletedOnboarding == true`):** Renders a native iPadOS `NavigationSplitView` with:
  - **Sidebar:** A `List` of patient records queried via `@Query` from SwiftData. A new chart is created with the "New Chart" button, and swipe-to-delete removes records. If empty, a `ContentUnavailableView` with a tray icon is shown. Sidebar background and toolbar are styled with dark navy (`Color(red: 0.05, green: 0.2, blue: 0.5)`), text forced to `.dark` color scheme so white labels are legible.
  - **Detail:** `ChartDashboard(columnVisibility: $columnVisibility)` with its own navigation bar hidden.

Passes a `$columnVisibility` binding to `ChartDashboard` so the dashboard can programmatically collapse the sidebar (e.g., when AI Mode activates) and the floating sidebar-restore button knows whether to appear.

---

#### `App/ModelLoadingSplash.swift`

Shown during initial model load. Renders a branded loading screen with a progress indicator while `Wav2VecEngine.loadModel()` completes.

---

### 3.2 `Views/Chart/`

#### `Views/Chart/ChartDashboard.swift`

The **root interactive viewport** and sole owner of global chart state. Also houses the `ZoomController`, `ZoomableContainer`, and `ChartContentView` structs.

**State properties:**

| Property | Type | Role |
|---|---|---|
| `mouth` | `[Int: ToothObject]` | Complete clinical record. Initialised via `fullMouthEmpty()`. Rebuilt from `commandHistory` on every voice command emission. |
| `isSingleColumn` | `Bool` | Toggles between 1-column (all quadrants stacked, 1.35× scale boost) and 2-column (upper/lower pairs side-by-side) layout. |
| `zoomController` | `ZoomController` | `@StateObject` managing `finalScale`. Connected to a custom vertical slider anchored to the bottom right. |
| `selectionModel` | `ChartSelectionModel` | `@StateObject` injected as `@EnvironmentObject`. Stores `Set<ChartCellCoordinate>` of highlighted cells. |
| `aiViewModel` | `AIVoiceViewModel` | `@StateObject` for the voice pipeline. Observed via `.onChange` for cursor, selection, and command history updates. |
| `showAIMode` | `Bool` | Slides `AIListeningView` in from the trailing edge, zooms to 1.75×, and expands the scroll frame by 1000pt symmetrically for free-panning. |
| `showDebugMenu` | `Bool` | Presents `SelectionDebugMenu` as a `.sheet`. |
| `showSettings` | `Bool` | Presents `OnboardingView` in settings mode as a `.sheet`. |

**Floating toolbar:**

A custom `HStack` overlaid at `.topTrailing` on a dark navy pill (`RoundedRectangle(cornerRadius: 12)` filled with `Color(red: 0.05, green: 0.2, blue: 0.5)`):

| Button | SF Symbol | Action |
|---|---|---|
| AI Mode | `apple.intelligence` | Toggle `showAIMode`, collapse sidebar, animate zoom to 1.75× |
| 1 Column / 2 Columns | `rectangle.split.1x2` / `rectangle.split.2x2` | Toggle `isSingleColumn` |
| Zoom | `magnifyingglass` | Toggles visibility of the zoom slider anchored to the bottom-right |
| Debug | `ladybug` | Open `SelectionDebugMenu` sheet |
| Export | `square.and.arrow.up` | Placeholder (not yet implemented) |
| Settings | `gear` | Open `OnboardingView` sheet |

**`ZoomableScrollView` and zoom implementation:**

The zoom and pan logic lives in `ZoomableScrollView<Content: View>` (defined in its own file `Views/Chart/ZoomableScrollView.swift`), a `UIViewRepresentable` wrapper around UIKit's `UIScrollView`. The native `UIScrollView` provides superior high-performance zooming and free-panning without SwiftUI layout thrashing. It manually sizes the `UIHostingController.view` to its intrinsic content size and completely bypasses Auto Layout constraints to prevent bounds-resizing glitches during scale transforms. The inner `RootWrapperView` also applies `.ignoresSafeArea()` to prevent coordinate drift.

When AI Mode is active, massive content insets (`contentInset`) equal to the screen bounds are applied, and the camera automatically centers on the bounding rect emitted by `HighlightFramePreferenceKey` at the 30% mark from the left edge without any edge clamping.

**Command application:**

When the parser emits commands, `ChartDashboard` replays the entire `commandHistory` by rebuilding `mouth` from `fullMouthEmpty()` and calling `ChartProcessor.apply(command:to:)` for each command. This ensures determinism regardless of mid-stream partial parses.

**Ghosted preview:**

When `aiViewModel.committedCommands` is non-nil (i.e. live dictation is active), each cell checks whether its coordinate is backed by the committed set. Cells present in `commandHistory` but not in `committedCommands` render with reduced opacity, signalling that Whisper has not yet confirmed that portion of the transcript.

---

#### `Views/Chart/QuadrantView.swift`

Renders one dental quadrant:

- Displays the quadrant title (e.g. "Quadrant 1 (Upper Right)") and aspect labels ("Outer (Facial)" / "Inner (Palatal/Lingual)").
- Renders `SideLabelsView` (110pt wide) on the correct side (left for Q1/Q4, right for Q2/Q3 in 2-column mode), separated by a native `Divider()`.
- Lays out 8 `ToothColumnView` instances in an `HStack(spacing: 0)` so adjacent grid lines merge seamlessly.

**`SideLabelsView`** renders a fixed-width panel whose row heights exactly mirror `ToothColumnView`: 18pt per data row, 1pt hairline gaps from the `separator`-coloured background, and an 80pt graphic placeholder.

---

#### `Views/Chart/ToothColumnView.swift`

The **layout orchestrator** for a single tooth column. Fixed to **72pt width**, composed of four sub-sections in a `VStack(spacing: 4)`:

1. **Tooth number header** — 24pt `Text` showing the FDI number.
2. **`sharedGrid`** — `ImplantCheckCell` + `SingleValueCell` (Mobility). These are whole-tooth properties, not per-aspect.
3. **`aspectGrid`** — Full data grid for one aspect (outer or inner depending on jaw). For upper jaw: outer is at the top (Facial), inner at the bottom (Palatal). For lower jaw: reversed. Contains: `FurcationCell`, GM `TripleValueRow`, PD `TripleValueRow`, CAL `TripleValueRow`, Bleeding `BoolDotRow`, Plaque `BoolDotRow`.
4. **`toothGraphic`** — Two stacked `ToothGraphicSideView` instances.

**Grid hairlines:** `VStack(spacing: 1)` gaps reveal the parent's `Color(.separator)` background, creating hairline grid lines without any explicit `Divider()` calls inside cells. Column dividers are a 1pt `Color(.separator)` overlaid on the trailing edge of each column (except the last).

**Selection highlighting:** `ToothColumnView` reads `ChartSelectionModel` from the environment. Each sub-view receives a `selectedSites: [Bool]` array. When a site is selected, its `ZStack` overlays a `HighlightBorder()`, which draws a 2pt orange border and emits its absolute coordinates via `HighlightFramePreferenceKey` for camera tracking. PD values ≥ 4 mm are rendered in `.red` (controlled by the `isProbingDepth` flag on `TripleValueRow`).

**Manual editing:**
- **Numeric data:** Tapping a numeric cell sets an `activePopover` state to bring up a `.fullScreenCover` containing the `NumberPadPopoverView`. Using `fullScreenCover` over a native `.popover` ensures that coordinate scaling from deep zoom magnifications doesn't break popover placement or cause rendering lag.
- **Furcation & Implants:** Tapping a furcation cell cycles its graphical value directly (0 → 1 → 2 → 3 → 0) without needing a popover. Implants toggle instantly via a tap.

---

#### `Views/Chart/ToothRowViews.swift`

Defines all cell types used inside `ToothColumnView`:

| Struct | Height | Appearance |
|---|---|---|
| `ImplantCheckCell` | 18pt | SF Symbol `checkmark.square.fill` (blue) or `square` (separator-coloured). Orange border when selected. Hatched pattern when missing. |
| `SingleValueCell` | 18pt | Secondary-styled text showing mobility grade (0–3). Orange border when selected. Hatched when missing. |
| `FurcationCell` | 18pt | N equal sub-cells, one per root. Displays dynamic graphical indicators (empty circle, half-filled circle, full circle) based on `FurcationClass`. Tapping cycles values directly. Rendered at `zIndex(1)` to float above chart lines. `HatchedPattern` fill when no furcation slot anatomically exists. |
| `TripleValueRow` | 18pt | 3 equal cells. PD values ≥ 4 coloured red. Hatched when missing. |
| `BoolDotRow` | 18pt | 3 cells each with a filled (6pt) or stroked (6pt) `Circle`. Red for Bleeding, blue for Plaque. |
| `HatchedPattern` | flexible | 45° diagonal lines at 6pt spacing drawn via `GeometryReader`-driven `Path` over a semi-transparent `tertiarySystemBackground`. |

---

#### `Views/Chart/ToothGraphicSideView.swift`

Handles the complex `Path` drawing for the clinical line chart embedded in each tooth column. Conforms to `Equatable` for SwiftUI culling.

**Layout constants:**

| Constant | Value | Meaning |
|---|---|---|
| `rootHeight` | 50pt | Coordinate space for root-level measurements (0–10mm scale) |
| `crownHeight` | 30pt | Reserved space for the crown region |
| `lineSpacing` | 5pt/mm | `rootHeight / 10` — each mm maps to 5pt of Y travel |
| Total height | 80pt | `rootHeight + crownHeight` |

A reference grid of 11 horizontal lines (0–10mm) is drawn at opacity 0.5 / lineWidth 0.5 for visual scale.

**GM Line (red) — `createGMPath`:**

The gingival margin line represents the gum line relative to the CEJ:
- GM values are **negated** before Y mapping. Positive GM = pseudopocket (gum above CEJ) = should plot above the CEJ baseline. SwiftUI Y increases downward, so without negation a positive GM would plot downward. Negation corrects this to match anatomical convention.
- 5 X-positions: left edge (blended), `w/6`, `w/2`, `5w/6`, right edge (blended). If the neighbouring tooth is `.missing`, lines stretch to the 0/full-width boundaries.
- **Inter-tooth blending:** Left edge = average of current tooth's mesial GM and the previous tooth's distal GM. Right edge = average of current tooth's distal GM and next tooth's mesial GM. Produces a seamless continuous line across all teeth in the quadrant.
- Rendered with `.red`, lineWidth 1.5, round cap/join. Red GM lines render *above* the blue PD lines on the Z-axis.

**PD Line (blue) — `createPDPath`:**

The probing depth line represents the bottom of the periodontal pocket:
- Plotted at `pd[i] - gm[i]` (distance from the gingival margin down to the pocket base). The blue line always sits below the red line.
- Uses the same inter-tooth blending logic.
- Rendered with `.blue`, lineWidth 1.5, round cap/join.

**Mirroring:**

`isMirrored = true` flips the Y coordinate:
- Non-mirrored: `y = rootHeight - val * lineSpacing` (root points down, crown at top).
- Mirrored: `y = crownHeight + val * lineSpacing` (root points up, crown at bottom).

For upper jaw: outer (facial) is non-mirrored (top), inner (palatal) is mirrored (bottom). For lower jaw: reversed. This ensures roots always point toward the dental arch center, consistent with WHO charting convention.

**Implant rendering:**

When `tooth.implant == true`, the natural tooth asset is replaced with surgical implant screw assets:
- Precision-mapped to each tooth's physical CEJ width using a computed `cejWidthRatios` lookup table derived from alpha-channel pixel analysis of the 64 raw PNG assets.
- Differentiates anatomically between molars (using `implant_screw_end` at 85% and `implant_screw_body` at 80% width) and non-molars (using just `implant_screw_body` at 100% true CEJ width).
- The screw body dynamically stretches down to the 10th grid row (full root depth) to ensure consistent lengths across all teeth, maintaining its calculated width without aspect-ratio distortion.
- Aligned along the Y-axis to match the standard 0 CEJ baseline for the jaw.

---

#### `Views/Chart/NumberPadPopoverView.swift`

A full-screen numeric entry interface presented as a `.fullScreenCover` when a numeric data cell is tapped. Using `fullScreenCover` instead of a native `.popover` prevents coordinate scaling from deep zoom magnifications from breaking popover placement or causing rendering lag. The view accepts the current value and a callback to commit the new value.

---

### 3.3 `Views/Voice/`

#### `Views/Voice/AIListeningView.swift`

A floating overlay panel that slides in from the trailing edge in AI Mode. Fills **40% of viewport width** and **80% of height**.

**Visual design:** `.ultraThinMaterial` background forced to `.light` color scheme, clipped to `RoundedRectangle(cornerRadius: 24)`. An orange-to-deep-orange gradient border (`LinearGradient`) pulses on a 1.5s repeating `easeInOut` animation. A soft shadow (`radius: 20, x: -10, y: 10`) creates depth.

**Header controls:**

- **AI Mode icon** — `apple.intelligence` SF Symbol with orange gradient and `.pulse` symbol effect.
- **Live mic button** — Gated on `Wav2VecViewModel.isModelReady`. Shows a `ProgressView` spinner while the model is loading, then a `mic` / `mic.fill` icon. Tapping calls `viewModel.toggleLiveDictation()`. Active state renders the icon red with a pulse effect.
- **Simulation play/stop button** — `play.circle.fill` / `stop.circle.fill`. Calls `viewModel.toggleSimulation(from: viewModel.selectedTestTranscript)`. Independent of the live mic — the two modes are mutually exclusive at runtime.

**Speaker gate status strip** (visible only during live dictation):

Displays `Wav2VecViewModel.gateStatus` — a `GateStatus` struct with fields: active, extractorReady, silencing, spans, rejected, extracted, rescued, lastDistance.

**Three content sections:**

1. **Live Transcription** — scrollable monospace `footnote`-sized `Text` showing the accumulating `liveTranscription` string. Minimum 120pt height (~5 lines).
2. **Current Command** — structured card with three rows:
   - *Operation* — `currentMetric.displayName` from the active cursor (e.g., "Probing Depth").
   - *Selection* — current tooth number from the cursor.
   - *Pending / Last Applied Values* — `HStack` of capsule-outlined value chips. Shows `pendingValues` when non-empty, otherwise the last applied command's values.
3. **History** — last 5 `AnnotationCommand` values in reverse-chronological order, each rendered as a `HistoryCard` with operation name and tooth/values.

---

### 3.4 `Views/Onboarding/`

#### `Views/Onboarding/OnboardingView.swift` & `AnnotationVisualizerView`

A unified configuration interface for both initial onboarding and in-app settings (`isSettingsMode` flag).

**Section 1 — Voice Sample Calibration:**
- Displays an Indonesian calibration sentence for the clinician to read aloud.
- Integrates with `AudioManager` to request microphone permissions (via `AVAudioApplication.requestRecordPermission`), record a 16kHz WAV voice sample, and manage playback.
- `hasRecorded` flag gates the "Complete Setup" / "Save" button.

**Section 2 — Annotation Order Configuration:**

**`TwoItemReorderable<Item, Content>`** (extracted to `TwoItemReorderable.swift`) — a generic `View` for zero-delay drag-reordering of exactly 2 items. Bypasses SwiftUI's built-in `onDrag` limitations (long-press delay, translucent snapshot) using a raw `DragGesture`:
- Tracks `draggingItem`, `dragOffset`, and `isSwapped`.
- The non-dragging item animates to its swapped offset (`+/-(itemHeight + spacing)`) during drag for immediate visual feedback.
- On `onEnded`, if `isSwapped`, calls `swapAt(0, 1)` on the binding array.
- Item heights are measured dynamically via `GeometryReader` so the component works regardless of card size.

**`jawFirstHierarchyView`** (when `primaryOrder == .jawFirst`):
- Two outer `TwoItemReorderable` cards for jaw order (Upper/Lower).
- Each jaw card contains a nested `TwoItemReorderable` for its aspect order (Buccal/Palatal).
- Each aspect row includes a `Picker` for traversal direction (Left to Right / Right to Left).

**`aspectFirstHierarchyView`** (when `primaryOrder == .aspectFirst`):
- Two outer cards for aspect order (Buccal/Palatal).
- Each aspect card contains a nested `TwoItemReorderable` for jaw order (Upper/Lower).
- Same direction picker per row.

**`AnnotationVisualizerView`** (extracted to `AnnotationVisualizerView.swift`) — a live top-down teeth preview re-rendering on every config change. Shows two `JawVisualizer` instances (upper/lower), each displaying a 16-block placeholder tooth strip flanked by traversal arrows. The view accurately reflects the standard WHO periodontal chart format by rendering the upper jaw with Outer Side (top) to Inner Side (bottom), and the lower jaw with Inner Side (top) to Outer Side (bottom). The step number (e.g., "1.", "2.") is computed by `ChartingConfiguration.sequenceIndex(for:aspect:)`.

**Configuration persistence:** Encoded with `JSONEncoder` and stored in `UserDefaults` under key `"ChartingConfiguration"`. Read back in `OnboardingView.onAppear` and `AIVoiceViewModel.getConfiguration()`.

---

### 3.5 `ViewModels/`

#### `ViewModels/AIVoiceViewModel.swift`

An `@MainActor` `ObservableObject` that orchestrates the voice pipeline — both debug simulation and real live dictation — and maintains the live state of the NLP pipeline.

**State properties:**

| Property | Type | Role |
|---|---|---|
| `liveTranscription` | `String` | The raw incoming text stream, updated continuously during simulation or live dictation. |
| `isListening` | `Bool` | True while the debug simulation is running. |
| `isDictating` | `Bool` | True while real live dictation is active. The two modes are mutually exclusive. |
| `currentCommand` | `AnnotationCommand?` | The most recent command emitted by the parser. |
| `commandHistory` | `[AnnotationCommand]` | Complete list of all applied mutations. `ChartDashboard` listens to this to rebuild the mouth. During live dictation, derived from the full preview transcript. |
| `committedCommands` | `[AnnotationCommand]?` | Commands parsed from confirmed chunks only. `nil` during simulation/instant fill (no ghosting). Non-nil during live dictation — cells not in this set render ghosted. |
| `currentCursor` | `ChartingCursor?` | Current traversal position of the parser. |
| `activeSelection` | `TeethSelection?` | Any explicitly targeted out-of-sequence selection. |
| `pendingValues` | `[String]` | Numbers buffered by the parser but not yet committed. |
| `wpm` | `Double` | Simulation playback speed (20–300 WPM). Adjustable via debug slider. |
| `selectedTestTranscriptName` | `String` | Name key of the currently selected test transcript. |
| `selectedTestTranscript` | `String` *(computed)* | Looks up `TestTranscripts.all` by `selectedTestTranscriptName`. |

**Key methods:**

- **`toggleSimulation(from:)`** — If already listening, stops the simulation. Otherwise starts it. Stops live dictation first (mutually exclusive).
- **`toggleLiveDictation()`** — Primary public method called by `AIListeningView`. Wires `Wav2VecViewModel.onLiveTranscript` / `onConfirmedTranscript` callbacks and calls `startLiveDictation()` or `stopLiveDictation()` based on `isDictating`.
- **`startSimulation(from:)`** *(private)* — Splits the transcript into words (expanding `\n`, `.`, `,` as discrete tokens). Resets state, then spawns an `@MainActor` bound `Task` that appends one word per loop iteration. Parsing is offloaded to a detached thread via `Task.detached` calling a `nonisolated` helper (`parseOffline`) to prevent UI hitching during dense token streams. Sets `committedCommands = nil` (no ghosting in simulation mode).
- **`parseInstant(text:)`** — Stops any running simulation/dictation, runs a fresh `StatefulParser` with `isFinal: true` on the given text. Sets `committedCommands = nil` (no ghosting). Used by the Debug menu's **Fill Chart** and **Test Debug Transcript** buttons.
- **`startLiveDictation()`** — Hooks `Wav2VecViewModel.onLiveTranscript` → `ingestPreview` (full transcript → chart preview) and `onConfirmedTranscript` → `ingestCommitted` (confirmed-only → committed set). Calls `Wav2VecViewModel.startLive()`.
- **`stopLiveDictation()`** — Stops the stream, performs a final `isFinal: true` parse over the full accumulated transcript, and sets `committedCommands = commandHistory` so no cells remain ghosted.
- **`ingestPreview(_:isFinal:)`** *(private)* — Parses the full running transcript (skips if text unchanged). Updates `commandHistory`, `currentCommand`, `currentCursor`, `activeSelection`, `pendingValues`.
- **`ingestCommitted(_:)`** *(private)* — Parses confirmed-only text. Updates `committedCommands`. The chart uses this to determine ghosting.
- **`initializeCursorIfNeeded()`** — Creates an initial `ChartingCursor` when AI Mode is first opened.

**Static properties:**

| Property | Type | Role |
|---|---|---|
| `debugTranscript` | `static let String` | A hardcoded short transcript used by the **Test Debug Transcript** debug button for quick iteration without the transcript picker. |

---

### 3.6 `Debug/`

#### `Debug/SelectionDebugMenu.swift`

A developer `.sheet` presented as a `NavigationStack` with `List` sections. Receives `mouth: [Int: ToothObject]` as a `@Binding` and both `ChartSelectionModel` and `AIVoiceViewModel` as `@EnvironmentObject` injections.

**Section: Chart Overrides**
- **All Implants** toggle — sets `implant = true/false` on every tooth in `mouth` directly via the binding. No parser involvement.

**Section: Speaker Gate (TSE)**
- `NavigationLink` to `SpeakerGateDebugView`, which is the enrollment + verification test harness for the ECAPA-TDNN speaker gate.

**Section: Session Recorder**
- Toggle for `SessionRecorder` (records raw+gated audio per session for debug).

**Section: NLP Phase 1 Tokenizer**
- `Toggle` bound to `@AppStorage("useMLTokenizer")`. Switches the active Phase 1 tokenizer at runtime between `MLVoiceTokenizer` (IndoBERT CoreML) and the rule-based `VoiceTokenizer` without restarting the app.

**Section: AI Simulation**
- `Slider` for `aiViewModel.wpm` in the range 20–300, step 10.

**Section: Instant Fill (Testing)**
- `Picker` bound to `aiViewModel.selectedTestTranscriptName` listing all entries in `TestTranscripts.all`.
- **Fill Chart** button — calls `aiViewModel.parseInstant(text:)` with the selected transcript and immediately dismisses the sheet.
- **Test Debug Transcript** button — calls `aiViewModel.parseInstant(text: AIVoiceViewModel.debugTranscript)` with the static hardcoded debug transcript string for quick iteration without the picker.
- **Clear Chart** (destructive) — calls `parseInstant(text: "")` and removes all `selectionModel.selectedCells`.

**Section: Regression Testing**
- **Save as Ground Truth** — parses the currently selected transcript via `ChartTestingUtilities.parseTranscript(text:config:)`, then writes the resulting `[ToothObject]` JSON array to the ground truth file. Shows a success/failure alert.
- **Test vs Ground Truth** — loads the ground truth JSON, re-parses the selected transcript, and calls `ChartTestingUtilities.compareCharts(expected:actual:)`. Results are displayed in an alert: `✅ Regression Test PASSED` or `❌ Regression Test FAILED` with per-tooth difference strings.

> [!NOTE]
> On a **physical iOS device**, ground truth files are written to the app’s `Documents/` sandbox folder. On the **Simulator** or macOS, `#if targetEnvironment(simulator)` directs the save path directly to the project’s `Testing/Ground/` folder so files are checked into source control immediately.

**Section: Single Cell Highlights**
- Pre-built scenarios for individual cell and mid-site highlights (e.g. “Tooth 16 Probing Depth (Outer)”, “Tooth 21 Bleeding (Inner, Mid)”) for UI verification without invoking the voice pipeline.

**Section: Row / Region Highlights**
- Pre-built multi-cell scenarios (e.g. “Q1 Gingival Margin (Outer)”, “All Implants (Shared Grid)”).

**Section: Clear**
- **Clear All Selections** (destructive) — empties `selectionModel.selectedCells` without clearing the chart.

---

#### `Debug/SessionRecorder.swift`

A `final class SessionRecorder` singleton that captures one dictation session as two sample-aligned WAV files: `session-raw.wav` (what the mic heard) and `session-gated.wav` (what Wav2Vec received after gating/extraction).
- OFF by default (`isEnabled` flag persisted in UserDefaults).
- Called from `Wav2VecViewModel`: `begin()` at `startLive()`, `append(raw:gated:)` after each `performCommit`, `finish()` at `stopLive()`.
- Withheld chunks (all spans rejected) write SILENCE to `session-gated.wav` to maintain sample alignment.
- Files stored in `Documents/DebugSessions/`, excluded from backup, protected with `.completeUnlessOpen`.
- Accessible for playback via `SpeakerGateDebugView`.

---

#### `Debug/SpeakerGateDebugView.swift`

Provides an enrollment + verification test harness for the ECAPA-TDNN speaker gate.

---

#### `Debug/ChartTestingUtilities.swift`

A static utility struct providing the headless save/load/compare pipeline used by both the in-app debug menu and the CLI test runner.

| Method | Signature | Description |
|---|---|---|
| `getFileURL()` | `-> URL` | Returns the path to the ground truth JSON. On Simulator/macOS, resolves to `Testing/Ground/` in the project source tree. On a physical device, resolves to the app `Documents/` sandbox. |
| `saveChart(mouth:)` | `([Int: ToothObject]) -> Bool` | Encodes the mouth dict as a sorted `[ToothObject]` JSON array (pretty-printed) and writes it to disk. |
| `loadChart()` | `-> [Int: ToothObject]?` | Reads the ground truth JSON, decodes `[ToothObject]`, and rebuilds the `[Int: ToothObject]` dictionary. |
| `compareCharts(expected:actual:)` | `([Int:ToothObject], [Int:ToothObject]) -> [String]` | Iterates all teeth in `expected`. Checks `probingDepth`, `gingivalMargin`, `bleeding`, `plaque`, and `missing` for equality. Returns human-readable difference strings, empty if charts match exactly. |
| `parseTranscript(text:config:)` | `@MainActor (String, ChartingConfiguration) -> [Int: ToothObject]` | Creates a fresh `StatefulParser`, calls `consume(tokens: allTokens, isFinal: true)`, applies all commands via `ChartProcessor.apply`, and returns the final mouth state. |

> [!IMPORTANT]
> `saveChart` and `loadChart` depend on all chart types being `Codable`. `MobilityClass`, `FurcationClass`, `FurcationData`, `AspectData<T>`, and `ToothObject` all conform to `Codable`.

---

### 3.7 `Models/`

#### `Models/Models.swift`

All chart state is expressed through a strictly typed value-type model. The single source of truth is `mouth: [Int: ToothObject]` in `ChartDashboard`, keyed by FDI tooth number.

**`ToothObject` (Codable, Identifiable, Equatable):**

| Property | Type | Description |
|---|---|---|
| `toothNumber` | `Int` | FDI number (11–18, 21–28, 31–38, 41–48) |
| `probingDepth` | `AspectData<Int>` | Pocket depth in mm per site (3 sites per aspect). Clamped globally to `0...16` via `didSet`. |
| `gingivalMargin` | `AspectData<Int>` | CEJ-to-gum distance in mm. Negative = recession, positive = pseudopocket. Clamped globally to `-10...10` via `didSet`. |
| `mobility` | `MobilityClass` | Tooth mobility grade 0–3 |
| `furcation` | `FurcationData?` | `nil` for single-rooted / anterior teeth |
| `bleeding` | `AspectData<Bool>` | Bleeding on probing per site |
| `plaque` | `AspectData<Bool>` | Plaque present per site |
| `missing` | `Bool` | Edentulous site |
| `implant` | `Bool` | Osseointegrated implant present |
| `attachmentLevel` | `AspectData<Int>` *(computed)* | CAL = PD − GM, element-wise via `zip` |

**`AspectData<T>`:**

Generic `Equatable & Codable` container. `outer: [T]` (Facial/Buccal) and `inner: [T]` (Palatal/Lingual), each 3 elements ordered `[mesial, mid, distal]`.

**`MobilityClass` / `FurcationClass`:**

`Int`-backed `CaseIterable` enums ranging 0–3.

**Furcation anatomy:**

| Tooth | Outer roots | Inner roots | Notes |
|---|---|---|---|
| Maxillary Molars (16,17,18,26,27,28) | 1 | 2 | 3 roots total: 1 buccal + 2 palatal |
| Maxillary 1st Premolars (14,24) | 0 | 2 | 2 roots: 1 buccal + 1 palatal |
| Mandibular Molars (36–38, 46–48) | 1 | 1 | 2 roots: 1 mesial + 1 distal |
| All other teeth | — | — | `furcation = nil` |

When no furcation slot exists for an aspect, `HatchedPattern` is rendered. When `tooth.missing = true`, all data cells use `HatchedPattern` and hide values.

**`ChartCellCoordinate`:**

A `Hashable` struct uniquely identifying any cell in the chart:

```swift
struct ChartCellCoordinate: Hashable {
    var toothNumber: Int
    var operation: AnnotationOperation
    var aspect: ChartAspect?  // nil for shared grids (Implant, Mobility)
    var siteIndex: Int?       // 0/1/2 = mesial/mid/distal. nil for single-value cells
}
```

**`TeethSelection`:**

Represents a parsed target range. `expectedSlots` is the count of `(tooth, aspect, site)` tuples from start to end (computed via `ChartAnatomyResolver.sequence`), driving how many values the parser must collect before flushing.

**`ChartAnatomyResolver`:**

Static utility with two key functions:
- **`resolve(anatomy:for:currentAspect:)`** — Maps an `AnatomyType` token to `(ChartAspect?, siteIndex: Int?)`. Handles the right-side mirror: on teeth 11–18 and 41–48, "mesial" = site index 2 (distal from chart perspective); on 21–28 and 31–38, "mesial" = site index 0.
- **`sequence(from:to:)`** — Returns the contiguous `[(tooth, aspect, site)]` slice between two coordinates in canonical mouth order. Powers both range command parsing and highlight mask generation.

**Factory methods:**

| Method | Returns |
|---|---|
| `ToothObject.create(number:)` | Zeroed tooth with anatomically correct furcation slots |
| `ToothObject.mock(number:)` | Randomised data for testing |
| `fullMouthEmpty()` | Dict of 32 zeroed teeth |
| `fullMouthMock()` | Dict of 32 randomised teeth |

---

#### `Models/ChartProcessor.swift`

Provides a static pure function for mutating a `[Int: ToothObject]` dictionary given an `AnnotationCommand`. Used by `ChartDashboard` to replay history and by `ChartTestingUtilities` for test evaluation.

```swift
struct ChartProcessor {
    static func apply(command: AnnotationCommand, to mouthState: inout [Int: ToothObject])
}
```

Dispatches on the command's geometry:

| Shape | Condition | Behaviour |
|---|---|---|
| **Anatomy-site range** | `startAspect` and `endAspect` both non-nil | Calls `ChartAnatomyResolver.sequence(from:to:)` to get the ordered `(tooth, aspect, site)` list; applies values element-wise. |
| **Same-tooth, site range** | Same tooth, `startSite` non-nil | `endSite` defaults to `startSite` when nil (single-site selections). Iterates each `(aspect, site)` pair consuming indexed values. |
| **Multi-tooth range** | Start and end tooth differ, no aspect boundaries | Locates both teeth in the canonical 32-tooth order array, slices the range, consumes values in groups of 3 per tooth. |
| **Single-tooth / fallback** | Default | Directly sets the named property arrays on the tooth using `command.values`. |

> [!NOTE]
> `ChartDashboard` rebuilds `mouthState` from scratch by replaying the full `commandHistory` on every parser update. This guarantees the chart is always the deterministic result of the command log.

---

### 3.8 `Configuration/`

For the full specification of how `ChartingConfiguration` and `ChartingCursor` interact with the NLP pipeline, see [system_guide.md §10–11](system_guide.md). This section covers the Swift type definitions.

#### `Configuration/ChartingConfiguration.swift`

`ChartingConfiguration` is a `Codable, Equatable` struct serialised to `UserDefaults` under key `"ChartingConfiguration"`.

| Property | Default | Meaning |
|---|---|---|
| `primaryOrder` | `.jawFirst` | Complete one jaw at a time vs one aspect at a time |
| `jawOrder` | `[.upper, .lower]` | Which jaw is charted first |
| `upperAspectOrder` | `[.buccal, .palatal]` | Aspect order within the upper jaw |
| `lowerAspectOrder` | `[.buccal, .palatal]` | Aspect order within the lower jaw |
| `aspectOrder` | `[.buccal, .palatal]` | Aspect order in `aspectFirst` mode |
| `buccalJawOrder` | `[.upper, .lower]` | Jaw order when charting buccal aspect first |
| `palatalJawOrder` | `[.upper, .lower]` | Jaw order when charting palatal aspect first |
| `directionMapping` | Zig-zag (see below) | Per `(jaw, aspect)` direction, keyed as `"Upper-Buccal"` etc. |

**Default zig-zag direction mapping** (matches standard continuous clinical charting around the arch):

| Key | Default | Tooth sequence |
|---|---|---|
| `"Upper-Buccal"` | `.leftToRight` | 18 → 11 → 21 → 28 |
| `"Upper-Palatal"` | `.rightToLeft` | 28 → 21 → 11 → 18 |
| `"Lower-Buccal"` | `.rightToLeft` | 38 → 31 → 41 → 48 |
| `"Lower-Palatal"` | `.leftToRight` | 48 → 41 → 31 → 38 |

> [!IMPORTANT]
> Existing installs that cached old all-`.leftToRight` defaults via `UserDefaults` must manually correct the direction in **Settings**.

`getSequence(for:aspect:)` returns the ordered FDI tooth list for a jaw/aspect pair, respecting direction.

`sequenceIndex(for:aspect:)` (extension in `OnboardingView.swift`) returns the 1-based ordinal for a (jaw, aspect) pair in the full configured traversal order — used by `AnnotationVisualizerView` for step numbering.

**Enums defined in this file:**

| Enum | Cases |
|---|---|
| `PrimaryOrderType` | `.jawFirst`, `.aspectFirst` |
| `JawType` | `.upper`, `.lower` |
| `AspectType` | `.buccal`, `.palatal` |
| `AnnotationDirection` | `.leftToRight`, `.rightToLeft` |

---

#### `Configuration/ChartingCursor.swift`

`ChartingCursor` is a value-type `struct` tracking the sequential position in the configured annotation order. See [system_guide.md §10](system_guide.md) for the full method reference and traversal state machine description.

```swift
struct ChartingCursor: Equatable {
    var currentTooth: Int
    var currentAspect: ChartAspect        // .outer or .inner
    var currentMetric: AnnotationOperation // default: .probingDepth
    var configuration: ChartingConfiguration
    // private(set): primaryIndex, secondaryIndex, sequenceIndex, currentSequence
    var currentJaw: JawType { /* computed */ }
}
```

---

#### `Configuration/ToothFramePreferenceKey.swift`

Defines a SwiftUI `PreferenceKey` used by `ToothColumnView` to report each tooth column’s absolute frame coordinates upward to `ChartDashboard`. The dashboard collects these via `.onPreferenceChange` and uses them to drive the `ZoomableScrollView` camera, centering the viewport on the active cursor tooth during AI Mode without any hard-coded layout constants.

---

### 3.9 `Audio/`

The `Audio/` directory owns all real-time audio processing: voice recording, on-device speech-to-text, and speaker isolation.

#### `Audio/Capture/`

- **`AudioManager.swift`** — Singleton `ObservableObject` managing voice calibration recording and playback via `AVFoundation`. Captures 16kHz, mono, 16-bit linear PCM WAV (matches Wav2Vec2 input).

#### `Audio/Signal/`

- **`AutoGain.swift`** — An adaptive gain stage that normalizes speaking levels to a target RMS (0.1). Uses a slow-moving multiplier (~1.5 s time constant) with a hard ceiling (12x) and hold-during-silence rule (anti-pumping). Applied per 512-sample buffer in `startStreamingRecording`. Does NOT affect ECAPA speaker distances (ECAPA normalizes mean/variance per utterance, making gain changes invisible to identity verification).
- **`HighPassFilter.swift`** — 80 Hz IIR biquad high-pass filter. Removes sub-bass rumble from suction tubes and HVAC. Applied before AutoGain in the streaming path. Both carry stateful IIR state across buffers; `reset()` is called at the start of each session.

#### `Audio/Profiles/`

- **`CalibrationTake.swift`**, **`VoiceProfile.swift`**, **`VoiceProfileStore.swift`** — Manage stored voice profiles. `VoiceProfileStore` persists profiles to disk, applies backup exclusion and file protection.

#### `Audio/Speaker/`

- **`SpeakerGate.swift`** and **`SpeakerGateService.swift`** — Enrollment + multi-template centroid logic for ECAPA-TDNN.
- **`SpeakerVerdict.swift`** — Deprecated (entire file commented out as of 2026-08-13).

#### `Audio/TSE/`

- Target Speech Extraction pipeline orchestration (`TSEConfig`, `TSEEngine`, `TSEExtractor`, `TSEFeatures`, `TSERescue`).

#### `Audio/Transcription/`

- **`TranscriptionEngine.swift`** — Thin `@MainActor @Observable` singleton that provides `makeSpeakerGateIfNeeded() -> SpeakerGateService?`. It holds the app-wide `SpeakerGateService` and `VoiceProfileStore`. It is NOT the STT engine. Called from `Wav2VecViewModel.startLive()` to obtain the gate service.

#### `Audio/Wav2Vec/`

- **`Wav2VecEngine.swift`** — `@MainActor ObservableObject` singleton. `loadModel()` loads `Wav2Vec2_Indonesian_FP16.mlmodelc` from bundle (path searched in `AI/Wav2Vec_STT/`), builds `CTCDecoder` with `vocab.json`, `lexicon.txt`, `canonical_mapping.json`. `predict(audioData:isLivePreview:)` pads audio to 1-second bucket boundaries, runs CoreML inference, returns decoded string. `computeUnits = .cpuAndGPU`.
- **`Wav2VecAudioCapture.swift`** — `@MainActor ObservableObject` singleton. Captures mic audio via `AVAudioEngine`, resamples to 16kHz mono float32 via `AVAudioConverter`. `startStreamingRecording(onBuffer:)` applies `HighPassFilter` then `AutoGain` before emitting 512-sample chunks. `normalizeAudio(data:)` performs Z-score normalization (zero mean, unit variance) using `vDSP`. `readAudioFile(url:)` reads `.m4a` files via `AVAssetReader` decoded to 16kHz float32.
- **`Wav2VecViewModel.swift`** — `@MainActor @Observable final class`. Orchestrates the full live pipeline: mic → conditioning → energy-based VAD → commit → gate → extract → decode → parser. Published state: `transcript`, `statusMessage`, `isModelReady`, `isTranscribing`, `isRecording`, `gateStatus: GateStatus`. Callbacks: `onLiveTranscript`, `onConfirmedTranscript`. Key methods: `startLive()`, `stopLive() async`, `startSimulation(audio:speedMultiplier:)`. Commits are chained (each awaits its predecessor) to guarantee parser receives chunks in capture order. `GateStatus` struct reports: `active`, `extractorReady`, `silencing`, `spans`, `rejected`, `extracted`, `rescued`, `lastDistance`.
- **`CTCDecoder.swift`** — Prefix-Trie-constrained CTC beam search. `beamWidth = 10`. Characters not forming a valid prefix in the Trie are culled to -∞. After decoding, `Acoustic Cost Rejection` filters words where `costPerLetter > maxCostPerLetter (3.0)`. Destructive structural modifiers (`semua`, `sampai`, `hingga`, etc.) use a stricter threshold of `1.0`. Applies `canonical_mapping.json` patterns after decoding.
- **`PrefixTrie.swift`** — In-memory prefix trie built from `lexicon.txt` at startup. Supports `isValidPrefix(sequence:)` and `isWord(_:)` queries during CTC decoding.

---

### 3.10 `NLP/` Overview

The `NLP/` module is an offline processing pipeline that transforms raw Indonesian voice transcripts into deterministic clinical charting mutations. 

#### `NLP/Tokenizer/` (Phase 1)

Transforms an unstructured input string into a typed `[VoiceToken]` sequence.

| Tokenizer | Description |
|---|---|
| `VoiceTokenizer` | The rule-based tokenizer. Emits tokens using dictionary matches (`TokenizerLexicon`). |

- **`TokenizerManager`** — Singleton factory. Dispatches to `VoiceTokenizer` only.

#### `NLP/Parser/` (Phase 2)

Transforms a linear `[VoiceToken]` stream into structured `[AnnotationCommand]` operations. The parser maintains complex internal state.

| File | Responsibilities |
|---|---|
| `StatefulParser.swift` | Holds running context (`cursor`, `bufferedDigits`, `activeSelection`). Owns the main `consume()` loop and token dispatch switch. |
| `StatefulParser+Flush.swift` | Logic for assembling `bufferedDigits` into full `AnnotationCommand` objects and emitting them when a boundary token is hit (e.g. `flushNumbers()`, `discardOrFlush()`). |
| `StatefulParser+Lookahead.swift` | Handles lookahead strategies for fragmented digits (e.g. resolving `[digit_1] [digit_2] [digit_3]` vs `[digit_1] [to] [digit_3]`). |

---

### 3.11 `Testing/`

The `Testing/` directory contains tools and fixtures for running offline regression tests on the NLP pipeline.

#### `Testing/TestTranscripts.swift`

A struct exposing static transcript strings (`dr_lucky_ground`, `student_ground`) and a `all: [(String, String)]` array that drives the `Picker` in `SelectionDebugMenu`. Allows developers to run instantaneous parse tests inside the app via `AIVoiceViewModel.parseInstant(text:)`, bypassing the microphone and STT engine entirely.

#### `Testing/Raw/`, `Testing/Ground/`, `Testing/Suite/`

The regression suite tests full-session stamina (clinician-paced streams):

| Source Audio / Text | Ground Truth JSON | Purpose |
|---|---|---|
| `dr_lucky_audio.m4a` / `dr_lucky_ground.txt` | `ground_truth.json` | Real 5-minute continuous dictation by Dr. Lucky. Tests long-running stability, corrections, complex grammar, and realistic hesitation words. |
| `student_audio.m4a` / `student_ground.txt` | `student_ground.json` | Synthetic student-paced dictation (site-by-site). |
| `dr_gaby_audio.m4a` | - | Additional raw audio test set. |

- `Testing/Suite/` contains the regression test suite scripts and runner.

---

### 3.12 `AI/` (Model Bundles)

The `AI/` directory stores CoreML models and NLP assets. It is gitignored to avoid bloating the repo.

**`AI/Target_Speech_Extraction/`**
- `SpeakerEmbedding_ECAPA.mlpackage`
- `EnrollmentEncoder_WeSpeaker.mlpackage (TSE only, not the gate)`
- `EnrollmentProjection_BSRNN.mlpackage`
- `SpeakerConditioning_BSRNN.mlpackage`
- `TSEFrontend_BSRNN.mlpackage`
- `TSEMasker_BSRNN.mlpackage`
- `TargetSeparator_BSRNN.mlpackage`

**`AI/Wav2Vec_STT/`**
- `Wav2Vec2_Indonesian_FP16.mlpackage`
- `canonical_mapping.json`
- `lexicon.txt`
- `vocab.json`

---

### 3.13 `3D/`

- **`Model3DExporter.swift`** — Exports chart state for 3D visualization or external use.

---

## 4. Performance Architecture

The chart maintains 60 fps through gesture interactions and rapid AI cursor movements through three core architectural optimisations:

1. **Chart Culling (`ChartContentView`):** The entire layout of the 32 teeth is encapsulated in a dedicated `ChartContentView` that conforms to `Equatable`. Because dragging the zoom slider continuously mutates state on `ChartDashboard`, SwiftUI relies on the `.equatable()` modifier to mathematically skip layout re-evaluations for the chart content. This completely cuts the CPU overhead of diffing teeth, rows, and text fields during a slider drag, rendering it buttery smooth at 60fps.

2. **Equatable View Culling:** `ToothGraphicSideView` conforms to `Equatable`. When the AI Voice cursor highlights a new cell, `ToothColumnView` evaluates its layout but SwiftUI mathematically skips re-evaluating the expensive `ToothGraphicSideView` paths because the underlying tooth data hasn't changed.

3. **Metal Hardware Acceleration:** `ToothGraphicSideView` (which draws thousands of `Path` segments for GM, PD, and grid lines) has the `.drawingGroup()` modifier applied. This flattens the complex vector graphics into an off-thread Metal texture, drastically reducing CPU load during redraws.
