# Periodontal Charting — Frontend & Architecture Guide

This guide covers the project structure, component architecture, and Swift file-by-file reference for the Periodontal Charting app.

For the project brief and getting started instructions, see [project_guide.md](project_guide.md).
For the NLP command inference system, see [system_guide.md](system_guide.md).

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
4. [Performance Architecture](#4-performance-architecture)

---

## 1. Project Structure

```
PeriodontalCharting/
├── PeriodontalCharting.xcodeproj/
├── test_parser.sh                                 <- Shell: compile + run CLI regression tests
├── run_regression_tests.swift                     <- Swift @main for CLI test runner
└── PeriodontalCharting/                           <- App source root (auto-discovered by Xcode)
    │
    ├── App/
    │   ├── PeriodontalChartingApp.swift           <- @main entry point
    │   └── ContentView.swift                      <- Onboarding gate + NavigationSplitView shell
    │
    ├── Models/
    │   ├── Models.swift                           <- Core chart data types (all Codable)
    │   └── ChartProcessor.swift                   <- Shared, headless apply(command:to:) logic
    │
    ├── NLP/
    │   ├── Models/
    │   │   └── VoiceToken.swift                   <- Enums: ActionType, AnatomyType, VoiceToken
    │   ├── Tokenizer/
    │   │   ├── VoiceTokenizer.swift               <- Core base class
    │   │   ├── VoiceTokenizer+Helpers.swift       <- Tokenizing utilities
    │   │   └── VoiceTokenizer+Parsing.swift       <- Main text-to-token transformation loop
    │   └── Parser/
    │       ├── VoiceCommandParser.swift           <- State properties and init
    │       ├── VoiceCommandParser+Parse.swift     <- Main token processing loop
    │       ├── VoiceCommandParser+Flush.swift     <- Emission and flush logic
    │       └── VoiceCommandParser+Lookahead.swift <- Stream lookahead utilities
    │
    ├── Configuration/
    │   ├── ChartingConfiguration.swift            <- Config enums + ChartingConfiguration struct
    │   └── ChartingCursor.swift                   <- Traversal state machine
    │
    ├── Audio/
    │   └── AudioManager.swift                     <- AVFoundation recording/playback
    │
    ├── ViewModels/
    │   └── AIVoiceViewModel.swift                 <- Voice simulation + parser orchestration
    │
    ├── Views/
    │   ├── Chart/
    │   │   ├── ChartDashboard.swift               <- Root interactive viewport + state owner
    │   │   ├── QuadrantView.swift                 <- One dental quadrant + SideLabelsView
    │   │   ├── ToothColumnView.swift              <- Single tooth column layout
    │   │   ├── ToothRowViews.swift                <- Cell types: ImplantCheckCell,
    │   │   │                                         SingleValueCell, FurcationCell,
    │   │   │                                         TripleValueRow, BoolDotRow, HatchedPattern
    │   │   ├── ToothGraphicSideView.swift         <- Path-based GM/PD line chart per tooth side
    │   │   └── NumberPadPopoverView.swift         <- Full-screen numeric entry popover
    │   │
    │   ├── Voice/
    │   │   └── AIListeningView.swift              <- Voice overlay panel
    │   │
    │   └── Onboarding/
    │       ├── OnboardingView.swift               <- Main onboarding/settings view
    │       ├── TwoItemReorderable.swift           <- Generic drag-to-reorder for 2 items
    │       └── AnnotationVisualizerView.swift     <- Traversal-order preview diagram
    │
    ├── Debug/
    │   ├── SelectionDebugMenu.swift               <- Developer debug sheet
    │   └── ChartTestingUtilities.swift            <- Save / load / compare chart JSON
    │
    ├── Testing/
    │   ├── TestTranscripts.swift                  <- Static struct with embedded test transcripts
    │   ├── Raw/                                   <- Plain text per-feature test transcripts
    │   │   ├── dr_lucky_ground.txt                <- Full-session clinician transcript
    │   │   ├── student_ground.txt                 <- Student-style site-by-site transcript
    │   │   ├── C-01.txt … C-05.txt               <- "Commit/lanjut" feature tests
    │   │   ├── F-01.txt … F-06.txt               <- Furcation feature tests
    │   │   ├── I-01.txt … I-07.txt               <- Implant feature tests
    │   │   ├── M-01.txt … M-06.txt               <- Mobility feature tests
    │   │   └── N-01.txt … N-05.txt               <- Number/range feature tests
    │   └── Ground/
    │       ├── ground_truth.json                  <- Reference output for dr_lucky_ground
    │       ├── C-01_ground.json … N-05_ground.json <- Per-feature ground truth JSONs
    │
    ├── Documentation/
    │   ├── project_guide.md
    │   ├── frontend_guide.md                      <- This file
    │   └── system_guide.md
    │
    └── Assets.xcassets/
```

> [!NOTE]
> The testing infrastructure has been significantly expanded since the original documentation. `TestTranscripts/` has been reorganised into `Testing/` with `Raw/` and `Ground/` subdirectories. There are now 29 feature-specific transcripts (prefixed `C-`, `F-`, `I-`, `M-`, `N-`) alongside the two full-session transcripts, each paired with a ground truth JSON.

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

The `@main` entry point. A minimal `WindowGroup` wrapping `ContentView` — no environment injections at this level.

---

#### `App/ContentView.swift`

Serves as both the **onboarding gate** and the root layout shell. Reads `@AppStorage("hasCompletedOnboarding")` and branches:

- **First launch (`hasCompletedOnboarding == false`):** Renders `OnboardingView` directly as a full-screen view, bypassing the `NavigationSplitView` entirely.
- **After onboarding (`hasCompletedOnboarding == true`):** Renders a native iPadOS `NavigationSplitView` with:
  - **Sidebar:** A `List` of patient record strings (currently placeholder). If empty, a `ContentUnavailableView` with a tray icon is shown. Sidebar background and toolbar are styled with dark navy (`Color(red: 0.05, green: 0.2, blue: 0.5)`), text forced to `.dark` color scheme so white labels are legible.
  - **Detail:** `ChartDashboard(columnVisibility: $columnVisibility)` with its own navigation bar hidden.

Passes a `$columnVisibility` binding to `ChartDashboard` so the dashboard can programmatically collapse the sidebar (e.g., when AI Mode activates) and the floating sidebar-restore button knows whether to appear.

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

The zoom and pan logic lives in `ZoomableScrollView<Content: View>`, a `UIViewRepresentable` wrapper around UIKit's `UIScrollView`. The native `UIScrollView` provides superior high-performance zooming and free-panning without SwiftUI layout thrashing. It manually sizes the `UIHostingController.view` to its intrinsic content size and completely bypasses Auto Layout constraints to prevent bounds-resizing glitches during scale transforms. The inner `RootWrapperView` also applies `.ignoresSafeArea()` to prevent coordinate drift.

When AI Mode is active, massive content insets (`contentInset`) equal to the screen bounds are applied, and the camera automatically centers on the bounding rect emitted by `HighlightFramePreferenceKey` at the 30% mark from the left edge without any edge clamping.

**Command application:**

When the parser emits commands, `ChartDashboard` replays the entire `commandHistory` by rebuilding `mouth` from `fullMouthEmpty()` and calling `ChartProcessor.apply(command:to:)` for each command. This ensures determinism regardless of mid-stream partial parses.

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

**Three sections:**

1. **Live Transcription** — scrollable monospace `footnote`-sized `Text` showing the accumulating `liveTranscription` string. Minimum 120pt height (~5 lines).
2. **Current Command** — structured card with three rows:
   - *Operation* — `currentMetric.displayName` from the active cursor (e.g., "Probing Depth").
   - *Selection* — current tooth number from the cursor.
   - *Pending / Last Applied Values* — `HStack` of capsule-outlined value chips. Shows `pendingValues` when non-empty, otherwise the last applied command's values.
3. **History** — last 5 `AnnotationCommand` values in reverse-chronological order, each rendered as a `HistoryCard` with operation name and tooth/values.

**Simulation trigger:** A play/stop button in the header calls `viewModel.toggleSimulation(from: viewModel.selectedTestTranscript)`, running whichever transcript is currently selected in the debug menu at the configured WPM.

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

An `@MainActor` `ObservableObject` that orchestrates the voice parsing simulation and maintains the live state of the NLP pipeline.

**State properties:**

| Property | Type | Role |
|---|---|---|
| `liveTranscription` | `String` | The raw incoming text stream, updated word-by-word during simulation. |
| `isListening` | `Bool` | Whether the simulation or live microphone recording is currently active. |
| `currentCommand` | `AnnotationCommand?` | The most recent command emitted by the parser. |
| `commandHistory` | `[AnnotationCommand]` | Complete list of all applied mutations. `ChartDashboard` listens to this to rebuild the mouth. |
| `currentCursor` | `ChartingCursor?` | Current traversal position of the parser. |
| `activeSelection` | `TeethSelection?` | Any explicitly targeted out-of-sequence selection. |
| `pendingValues` | `[String]` | Numbers buffered by the parser but not yet committed. |
| `wpm` | `Double` | Simulation playback speed (20–300 WPM). Adjustable via debug slider. |
| `selectedTestTranscriptName` | `String` | Name key of the currently selected test transcript. |
| `selectedTestTranscript` | `String` *(computed)* | Looks up `TestTranscripts.all` by `selectedTestTranscriptName`. |

**Key methods:**

- **`toggleSimulation(from:)`** — If already listening, stops the simulation. Otherwise starts it.
- **`startSimulation(from:)`** *(private)* — Splits the transcript into words (expanding `\n`, `.`, `,` as discrete tokens). Resets state, then spawns an `@MainActor` bound `Task` that appends one word per loop iteration. The actual parsing is offloaded to a detached thread via `Task.detached` calling a `nonisolated` helper (`parseOffline`) to prevent UI hitching during dense token streams.
- **`parseInstant(text:)`** — Stops any running simulation, sets `liveTranscription = text`, and runs a fresh `VoiceCommandParser` with `isFinal: true`. All state is committed immediately. Used by the Debug menu's **Fill Chart** button.
- **`initializeCursorIfNeeded()`** — If `currentCursor == nil`, creates a new `VoiceCommandParser` and copies its initial cursor position. Called when AI Mode is first opened.
- **Flush timer** — A 1.5-second inactivity timer. If no new words arrive, the timer fires and runs a detached parse (`isFinal: true`) to force-flush any buffered values. After the last word in the array is consumed, a final flush also runs unconditionally. All view state mutations safely rejoin the main thread. Model types and the `VoiceCommandParser` itself explicitly conform to `@unchecked Sendable` to safely cross isolation boundaries without triggering incorrect `@MainActor` inference in Swift 6.

---

### 3.6 `Debug/`

#### `Debug/SelectionDebugMenu.swift`

A developer `.sheet` presented as a `NavigationStack` with `List` sections. Receives both `ChartSelectionModel` and `AIVoiceViewModel` as `@EnvironmentObject` injections.

**Section: AI Simulation**
- `Slider` for `aiViewModel.wpm` in the range 20–300, step 10.

**Section: Instant Fill (Testing)**
- `Picker` bound to `aiViewModel.selectedTestTranscriptName` listing all entries in `TestTranscripts.all`.
- **Fill Chart** button — calls `aiViewModel.parseInstant(text:)` with the selected transcript and immediately dismisses the sheet.
- **Clear Chart** (destructive) — calls `parseInstant(text: "")` and removes all `selectionModel.selectedCells`.

**Section: Regression Testing**
- **Save as Ground Truth** — parses the currently selected transcript via `ChartTestingUtilities.parseTranscript(text:config:)`, then writes the resulting `[ToothObject]` JSON array to the ground truth file. Shows a success/failure alert.
- **Test vs Ground Truth** — loads the ground truth JSON, re-parses the selected transcript, and calls `ChartTestingUtilities.compareCharts(expected:actual:)`. Results are displayed in an alert: `✅ Regression Test PASSED` or `❌ Regression Test FAILED` with per-tooth difference strings.

> [!NOTE]
> On a **physical iOS device**, ground truth files are written to the app's `Documents/` sandbox folder. On the **Simulator** or macOS, `#if targetEnvironment(simulator)` directs the save path directly to the project's `Testing/Ground/` folder so files are checked into source control immediately.

**Section: Single Cell Highlights**
- Pre-built scenarios for individual cell, row, and region highlights (e.g. "Tooth 16 Probing Depth (Outer)", "Q1 Gingival Margin (Outer)", "All Implants (Shared Grid)") for UI verification without invoking the voice pipeline.

---

#### `Debug/ChartTestingUtilities.swift`

A static utility struct providing the headless save/load/compare pipeline used by both the in-app debug menu and the CLI test runner.

| Method | Signature | Description |
|---|---|---|
| `getFileURL()` | `-> URL` | Returns the path to the ground truth JSON. On Simulator/macOS, resolves to `Testing/Ground/` in the project source tree. On a physical device, resolves to the app `Documents/` sandbox. |
| `saveChart(mouth:)` | `([Int: ToothObject]) -> Bool` | Encodes the mouth dict as a sorted `[ToothObject]` JSON array (pretty-printed) and writes it to disk. |
| `loadChart()` | `-> [Int: ToothObject]?` | Reads the ground truth JSON, decodes `[ToothObject]`, and rebuilds the `[Int: ToothObject]` dictionary. |
| `compareCharts(expected:actual:)` | `([Int:ToothObject], [Int:ToothObject]) -> [String]` | Iterates all teeth in `expected`. Checks `probingDepth`, `gingivalMargin`, `bleeding`, `plaque`, and `missing` for equality. Returns human-readable difference strings, empty if charts match exactly. |
| `parseTranscript(text:config:)` | `@MainActor (String, ChartingConfiguration) -> [Int: ToothObject]` | Creates a fresh `VoiceCommandParser`, runs `parse(text:isFinal:true)`, applies all commands via `ChartProcessor.apply`, and returns the final mouth state. |

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
| `ToothObject.mock(number:)` | PD `[3,5,2]`, GM `[0,-2,1]`, mid bleeding site |
| `ToothObject.fullMouthMock()` | All 32 teeth with mock data |
| `ToothObject.fullMouthEmpty()` | All 32 teeth zeroed — actual startup state |

**Voice annotation model:**

```swift
struct AnnotationCommand: Equatable {
    var operation: AnnotationOperation  // probingDepth, gingivalMargin, bleeding, etc.
    var teethSelection: TeethSelection
    var aspect: ChartAspect?
    var values: [String]               // measurements as strings
}
```

---

#### `Models/ChartProcessor.swift`

A shared, **UI-independent** `struct` that owns the canonical `apply(command:to:)` logic. It can be executed headlessly (in tests and the CLI runner) without instantiating any SwiftUI views.

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

### 3.9 `Audio/`

#### `Audio/AudioManager.swift`

Singleton `ObservableObject` managing all `AVFoundation` interactions.

**Published state:**

| Property | Meaning |
|---|---|
| `isRecording` | True while `AVAudioRecorder` is active |
| `isPlaying` | True while `AVAudioPlayer` is active |
| `hasRecording` | True if `voice_sample.wav` exists in Documents directory |
| `recordingURL` | Path to the WAV file |

**Recording format:** 16kHz, mono, 16-bit linear PCM WAV — matches input requirements of typical STT models (e.g., Whisper).

```swift
AVFormatIDKey: kAudioFormatLinearPCM
AVSampleRateKey: 16000.0
AVNumberOfChannelsKey: 1
AVLinearPCMBitDepthKey: 16
```

Session configured as `.playAndRecord` with `.allowBluetoothHFP` so clinicians can record via a Bluetooth headset. Conforms to `AVAudioRecorderDelegate` and `AVAudioPlayerDelegate` to clean up state on natural completion.

---

### 3.10 `NLP/` (Overview)

The NLP pipeline implements a three-phase architecture: **Tokenization → Parsing → Application**. For the complete specification of token types, parsing rules, targeting modes, lookahead utilities, and worked examples, see [system_guide.md](system_guide.md).

**Directory structure:**

| File | Responsibility |
|---|---|
| `NLP/Models/VoiceToken.swift` | `ActionType`, `AnatomyType`, `VoiceToken` enum definitions |
| `NLP/Tokenizer/VoiceTokenizer.swift` | Base class declaration |
| `NLP/Tokenizer/VoiceTokenizer+Helpers.swift` | Utility helpers |
| `NLP/Tokenizer/VoiceTokenizer+Parsing.swift` | Main `tokenize(text:isFinal:)` loop — normalization, spell correction, multi-word matching, number disambiguation |
| `NLP/Parser/VoiceCommandParser.swift` | State property declarations and `init(configuration:)` |
| `NLP/Parser/VoiceCommandParser+Parse.swift` | Main `parse(text:isFinal:)` token loop — all case handlers |
| `NLP/Parser/VoiceCommandParser+Flush.swift` | `flushNumbers`, `emitBoolIfPending`, `startPostTargeting`, `flushPostTargetIfPending`, `restoreToMainSequence` |
| `NLP/Parser/VoiceCommandParser+Lookahead.swift` | `resolveAnatomyWithLookahead`, `isContinuingList`, `hasUpcomingToothIdentifier` |

---

### 3.11 `Testing/`

#### `Testing/TestTranscripts.swift`

A top-level Swift file containing the `struct TestTranscripts` with two static `String` transcripts and a lookup array:

```swift
struct TestTranscripts {
    static let student_ground: String = "..."
    static let dr_lucky_ground: String = "..."

    static let allTranscripts = ["dr_lucky_ground", "student_ground"]
    static let all = [
        ("student_ground", student_ground),
        ("dr_lucky_ground", dr_lucky_ground),
    ]
}
```

> [!NOTE]
> The three-transcript `student_1_ground` / `student_2_ground` / `dr_lucky_ground` split from the original documentation has been consolidated. The current `student_ground` is a unified site-by-site transcript and `dr_lucky_ground` is the realistic clinician transcript. The `all` array drives the `Picker` in `SelectionDebugMenu` and `AIVoiceViewModel.selectedTestTranscript`.

**`dr_lucky_ground`:**

A realistic **sequence-based** full-mouth charting session by an experienced clinician. Demonstrates the broadest command vocabulary and is the primary regression test transcript. Exercises: tooth exclusion (`"gigi 18 gak ada"`), implicit sequence (`"2 2 2"` streams), range commands (`"resesi dari mesio bukal 17 sampai disto bukal 15 minus 1"`), BOP ranges, navigation (`"Lanjut"`, `"Lanjut palatal"`), jaw switching (`"rahang bawah"`), single-site targeting, verbal numbers (`"satu mili"`), and boolean mass-assignment (`"Plaque pada semua gigi"`).

**`student_ground`:**

A **site-by-site** style transcript structured around explicit anatomy calls per tooth. Uses `"Disto bukal N"`, `"Bukal N"`, `"Mesio Bukal N"` patterns and includes both buccal and lingual passes as separate blocks.

**Per-feature transcripts (`Testing/Raw/`):**

The `Testing/Raw/` directory contains 29 focused unit transcripts, each testing a specific feature or edge case:

| Prefix | Feature area |
|---|---|
| `C-01` to `C-05` | Commit / `lanjut` / `selesai` behaviour |
| `F-01` to `F-06` | Furcation scoring |
| `I-01` to `I-07` | Implant marking |
| `M-01` to `M-06` | Mobility grading |
| `N-01` to `N-05` | Number disambiguation and range handling |

Each has a paired ground truth JSON in `Testing/Ground/` (e.g. `C-01_ground.json`).

#### CLI Regression Testing (`test_parser.sh` + `run_regression_tests.swift`)

A fully **headless, terminal-executable** regression test for the NLP parsing pipeline. No Xcode or simulator required.

**Files at project root:**
- **`test_parser.sh`** — Compiles all necessary Swift source files (NLP, Models, Configuration, `ChartTestingUtilities`, `TestTranscripts`) using `swiftc` into a standalone binary (`test_runner`), then executes it.
- **`run_regression_tests.swift`** — The `@main` entry point for the CLI binary. Loads `ground_truth.json` from `Testing/Ground/`, parses `dr_lucky_ground` using the default `ChartingConfiguration()`, and reports differences.

**Usage:**
```bash
cd /path/to/PeriodontalCharting   # project root (where test_parser.sh lives)
./test_parser.sh
```

**Exit codes:**
- `0` — `✅ Regression Test PASSED: No differences found.`
- `1` — `❌ Regression Test FAILED:` followed by per-tooth difference strings, or an error if `ground_truth.json` is missing.

> [!IMPORTANT]
> The CLI runner always uses `ChartingConfiguration()` defaults (the zig-zag pattern). If you change the default configuration, re-generate `ground_truth.json` using the **Save as Ground Truth** button in the app's Debug menu before running the CLI test.

---

## 4. Performance Architecture

Given the visual density of the chart (32 teeth, each with complex vector paths and dozens of data cells), rendering performance is critical. The app maintains a steady 60fps during zoom gestures and rapid AI cursor movements through three core architectural optimisations:

1. **Chart Culling (`ChartContentView`):** The entire layout of the 32 teeth is encapsulated in a dedicated `ChartContentView` that conforms to `Equatable`. Because dragging the zoom slider continuously mutates state on `ChartDashboard`, SwiftUI relies on the `.equatable()` modifier to mathematically skip layout re-evaluations for the chart content. This completely cuts the CPU overhead of diffing teeth, rows, and text fields during a slider drag, rendering it buttery smooth at 60fps.

2. **Equatable View Culling:** `ToothGraphicSideView` conforms to `Equatable`. When the AI Voice cursor highlights a new cell, `ToothColumnView` evaluates its layout but SwiftUI mathematically skips re-evaluating the expensive `ToothGraphicSideView` paths because the underlying tooth data hasn't changed.

3. **Metal Hardware Acceleration:** `ToothGraphicSideView` (which draws thousands of `Path` segments for GM, PD, and grid lines) has the `.drawingGroup()` modifier applied. This flattens the complex vector graphics into an off-thread Metal texture, drastically reducing CPU load during redraws.
