# Periodontal Charting App

A comprehensive, iPad-optimised SwiftUI application for dental professionals to efficiently record and track periodontal disease clinical parameters using real-time voice commands.

---

## Table of Contents

1. [Overview & Project Context](#overview--project-context)
2. [Project Structure](#project-structure)
3. [Architecture](#architecture)
4. [File-by-File Reference](#file-by-file-reference)
5. [Data Model (Models.swift)](#data-model-modelsswift)
6. [NLP Voice Pipeline](#nlp-voice-pipeline)
7. [Configuration System](#configuration-system)
8. [Audio Infrastructure](#audio-infrastructure)
9. [Color Semantics](#color-semantics)
10. [Getting Started](#getting-started)
11. [Roadmap](#roadmap)

---

## Overview & Project Context

Periodontal charting is historically a highly manual process. A practitioner must simultaneously hold clinical instruments and dictate 3-6 numeric measurements per tooth site to an assistant who enters data — a process prone to transcription errors and inefficiency.

This project modernises the workflow in two phases:

1. **Phase 1 (Complete):** A WHO-standard, visually dense clinical chart that renders a full 32-tooth mouth across four quadrants. The chart scales seamlessly on iPad, supporting pinch-to-zoom and a 1-column vs 2-column layout toggle.

2. **Phase 2 (In Progress):** A real-time voice-transcription pipeline that converts clinical dictation in **Indonesian** (e.g., *"gigi 16 tiga empat lima tiga empat tiga"*) into structured `AnnotationCommand` mutations, enabling completely hands-free charting. The NLP engine is built, robustly handling complex clinical ranges, missing teeth, dynamic highlighting, and sequence traversals based on custom configurations.

### Key Design Principles

- **Clinical accuracy over aesthetics:** Every rendering decision (line direction, GM sign convention, mirroring logic) follows WHO and standard periodontal charting conventions.
- **Visually dense:** The chart fits all 32 teeth with full data grids on a single iPad screen, favouring legibility of numbers over whitespace.
- **Native SwiftUI:** No third-party design system dependency. All styling uses semantic SwiftUI colors and adaptive system fonts so Dark Mode, Dynamic Type, and accessibility work out of the box.
- **Indonesian-first NLP:** The voice pipeline is designed for Indonesian clinical dictation, recognising both written digits (`"3"`) and spoken Indonesian words (`"tiga"`), as well as clinical shorthand (`"gak ada"` = missing, `"lanjut"` = next tooth, `"BOP"` = bleeding on probing).

---

## Project Structure

```
PeriodontalCharting/
├── PeriodontalCharting.xcodeproj/
└── PeriodontalCharting/                         <- App source root (auto-discovered by Xcode)
    │
    ├── App/
    │   ├── PeriodontalChartingApp.swift         <- @main entry point
    │   └── ContentView.swift                    <- NavigationSplitView shell
    │
    ├── Models/
    │   └── Models.swift                         <- Core chart data types
    │
    ├── NLP/
    │   ├── VoiceTokenizer.swift                 <- ActionType, AnatomyType, VoiceToken, VoiceTokenizer
    │   └── VoiceCommandParser.swift             <- VoiceCommandParser state machine
    │
    ├── Configuration/
    │   ├── ChartingConfiguration.swift          <- Config enums + ChartingConfiguration struct
    │   └── ChartingCursor.swift                 <- ChartingCursor traversal state machine
    │
    ├── Audio/
    │   └── AudioManager.swift                   <- AVFoundation recording/playback
    │
    ├── ViewModels/
    │   └── AIVoiceViewModel.swift               <- Voice simulation + parser orchestration
    │
    ├── Views/
    │   ├── Chart/
    │   │   ├── ChartDashboard.swift             <- Root interactive viewport + state owner
    │   │   ├── QuadrantView.swift               <- One dental quadrant + SideLabelsView
    │   │   ├── ToothColumnView.swift            <- Single tooth column layout
    │   │   ├── ToothRowViews.swift              <- Cell types: ImplantCheckCell, SingleValueCell,
    │   │   │                                       FurcationCell, TripleValueRow, BoolDotRow, HatchedPattern
    │   │   └── ToothGraphicSideView.swift       <- Path-based GM/PD line chart per tooth side
    │   │
    │   ├── Voice/
    │   │   └── AIListeningView.swift            <- Voice overlay panel
    │   │
    │   └── Onboarding/
    │       ├── OnboardingView.swift             <- Main onboarding/settings view
    │       ├── TwoItemReorderable.swift         <- Generic drag-to-reorder for 2 items
    │       └── AnnotationVisualizerView.swift   <- Traversal-order preview diagram
    │
    ├── Debug/
    │   └── SelectionDebugMenu.swift             <- Developer debug sheet
    │
    ├── TestTranscripts/
    │   └── dr_lucky_ground.txt                  <- Reference clinical dictation sample
    │
    └── Assets.xcassets/
```

---

## Architecture

The application uses a modern, declarative SwiftUI component hierarchy. State flows top-down from the root `ChartDashboard` into individual `ToothColumnView` instances, which are read-only consumers of the `mouth` dictionary.

```
PeriodontalChartingApp
└── ContentView
    └── ChartDashboard          <- root state owner + toolbar
        ├── QuadrantView (Q1 - Upper Right)
        │   ├── SideLabelsView
        │   └── ToothColumnView x 8
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

### State Flow

- `ChartDashboard` owns `mouth: [Int: ToothObject]` (the entire clinical record) and two `@StateObject`s: `ChartSelectionModel` (which cells are highlighted orange) and `AIVoiceViewModel` (the voice pipeline state).
- `ChartSelectionModel` is injected as an `@EnvironmentObject`, allowing `ToothColumnView` to read highlight state without prop-drilling.
- When `AIVoiceViewModel.commandHistory` changes, `ChartDashboard.onChange` rebuilds `mouth` from scratch by replaying all commands in order. This ensures idempotency — replaying the full history always produces the same chart state regardless of mid-stream parsing artefacts.
- `ChartDashboard` observes `aiViewModel.currentCursor` to keep the `ScrollViewProxy` camera in sync with the underlying parser tooth position. It avoids listening to volatile `activeSelection` changes to prevent jittery, jumpy scrolling while applying in-place modifiers.

---

## File-by-File Reference

### `App/PeriodontalChartingApp.swift`

The `@main` entry point. A minimal `WindowGroup` wrapping `ContentView` — no environment injections required at this level.

---

### `App/ContentView.swift`

Serves as the root layout shell. Uses a native iPadOS `NavigationSplitView` presenting a patient record placeholder list in the sidebar and `ChartDashboard` in the detail pane. Passes a `$columnVisibility` binding to `ChartDashboard` so the dashboard can programmatically collapse the sidebar (e.g., when AI Mode activates) and the floating sidebar-restore button knows whether to appear. The navy blue `toolbarBackground` is applied here, giving the entire navigation chrome a consistent dark style.

---

### `Views/Chart/ChartDashboard.swift`

The **root interactive viewport** and sole owner of global chart state.

#### State properties

| Property | Type | Role |
|---|---|---|
| `mouth` | `[Int: ToothObject]` | Complete clinical record. Initialised via `fullMouthEmpty()`. Rebuilt from `commandHistory` on every voice command emission. |
| `isSingleColumn` | `Bool` | Toggles between 1-column (all quadrants stacked) and 2-column (upper/lower pairs side-by-side) layout. |
| `currentScale` / `finalScale` | `CGFloat` | Two-part zoom accumulator. `currentScale` tracks the live `MagnificationGesture` delta; `finalScale` is the committed result. Combined as `finalScale * currentScale`. Single-column mode applies an extra x1.35 factor. |
| `baseSize` | `CGSize` | Pre-scale layout size captured via `GeometryReader`. Required because `scaleEffect` scales visuals but not the layout frame — `ChartDashboard` manually sets the `ScrollView` content `frame` to `baseSize * scale` so scroll extents are correct after zooming. |
| `selectionModel` | `ChartSelectionModel` | `@StateObject` injected as `@EnvironmentObject`. Stores `Set<ChartCellCoordinate>` of highlighted cells. |
| `aiViewModel` | `AIVoiceViewModel` | `@StateObject` for the voice pipeline. Observed via `.onChange` for cursor, selection, and command history updates. |
| `showAIMode` | `Bool` | Slides `AIListeningView` in from the trailing edge, zooms to 1.75x, and expands the scroll frame by 1000pt symmetrically for free-panning. Zoom clamping is also removed. |
| `showDebugMenu` | `Bool` | Presents `SelectionDebugMenu` as a `.sheet`. |
| `showSettings` | `Bool` | Presents `OnboardingView` in settings mode as a `.sheet`. |

#### Floating toolbar

A custom `HStack` overlaid at `.topTrailing` on a dark navy pill (`RoundedRectangle(cornerRadius: 12)` filled with `Color(red: 0.05, green: 0.2, blue: 0.5)`):

| Button | SF Symbol | Action |
|---|---|---|
| AI Mode | `apple.intelligence` | Toggle `showAIMode`, collapse sidebar, animate zoom to 1.75x |
| 1 Column / 2 Columns | `rectangle.split.1x2` / `rectangle.split.2x2` | Toggle `isSingleColumn` |
| Reset Zoom | arrows icon | Set both scale vars to 1.0 |
| Debug | `ladybug` | Open `SelectionDebugMenu` sheet |
| Export | `square.and.arrow.up` | Placeholder (not yet implemented) |
| Settings | `gear` | Open `OnboardingView` sheet |

#### Zoom implementation detail

`scaleEffect` scales visuals but not the layout frame. `ChartDashboard` reads the pre-scale `baseSize` via a `GeometryReader` overlay and manually sets the `frame` to `baseSize * scale`. When AI Mode is active, the frame expands by 1000pt in both dimensions (`showAIMode ? 1000 : 0`) so the `ScrollViewProxy` auto-scroller can freely pan to teeth that would otherwise be locked against the absolute screen edges.

#### Command application — `apply(command:to:)`

When the parser emits commands, `ChartDashboard` replays the entire `commandHistory` by rebuilding `mouth` from `fullMouthEmpty()` and calling `apply(command:to:)` for each command. This ensures determinism regardless of mid-stream partial parses. Two cases:

1. **Range commands** (all of `startAspect`, `startSite`, `endAspect`, `endSite` non-nil): resolves the site sequence via `ChartAnatomyResolver.sequence(from:to:)` and applies values element-wise.
2. **Whole-tooth commands** (nil aspect/site): applies the value array directly to the tooth's outer or inner array.

#### FDI quadrant order

```
Q1: [18,17,16,15,14,13,12,11]  -- upper right
Q2: [21,22,23,24,25,26,27,28]  -- upper left
Q4: [48,47,46,45,44,43,42,41]  -- lower right (shown before Q3)
Q3: [31,32,33,34,35,36,37,38]  -- lower left
```

Q4 precedes Q3 to mirror the upper jaw layout and produce correct anatomical alignment in the 2-column view.

---

### `Views/Chart/QuadrantView.swift`

Renders one dental quadrant. It:

- Displays the quadrant title (e.g. "Quadrant 1 (Upper Right)") and aspect labels ("Outer (Facial)" / "Inner (Palatal/Lingual)").
- Renders `SideLabelsView` (110pt wide) on the correct side (left for Q1/Q4, right for Q2/Q3 in 2-column mode), separated by a native `Divider()`.
- Lays out 8 `ToothColumnView` instances in an `HStack(spacing: 0)` so adjacent grid lines merge seamlessly.

**`SideLabelsView`** renders a fixed-width panel whose row heights exactly mirror `ToothColumnView`: 18pt per data row, 1pt hairline gaps from the `separator`-coloured background, and an 80pt graphic placeholder.

---

### `Views/Chart/ToothColumnView.swift`

The **layout orchestrator** for a single tooth column. Fixed to **72pt width**, composed of four sub-sections in a `VStack(spacing: 4)`:

1. **Tooth number header** — 24pt `Text` showing the FDI number.
2. **`sharedGrid`** — `ImplantCheckCell` + `SingleValueCell` (Mobility). These are whole-tooth properties, not per-aspect.
3. **`aspectGrid`** — Full data grid for one aspect (outer or inner depending on jaw). For upper jaw: outer is at the top (Facial), inner at the bottom (Palatal). For lower jaw: reversed. Contains: `FurcationCell`, GM `TripleValueRow`, PD `TripleValueRow`, CAL `TripleValueRow`, Bleeding `BoolDotRow`, Plaque `BoolDotRow`.
4. **`toothGraphic`** — Two stacked `ToothGraphicSideView` instances. Upper jaw: outer on top (non-mirrored), inner below (mirrored). Lower jaw: inner on top (mirrored), outer below (non-mirrored).

**Row cell types** are defined in `ToothRowViews.swift` (extracted from this file). **Grid hairlines:** `VStack(spacing: 1)` gaps reveal the parent's `Color(.separator)` background, creating hairline grid lines without any explicit `Divider()` calls inside cells. Column dividers are a 1pt `Color(.separator)` overlaid on the trailing edge of each column (except the last).

**Selection highlighting:** `ToothColumnView` reads `ChartSelectionModel` from the environment. Each sub-view receives a `selectedSites: [Bool]` array. When a site is selected, its `ZStack` overlays a 2pt orange `strokeBorder`. PD values >= 4 mm are rendered in `.red` (controlled by the `isProbingDepth` flag on `TripleValueRow`).

#### Row types (defined in `ToothRowViews.swift`)

| Struct | Height | Appearance |
|---|---|---|
| `ImplantCheckCell` | 18pt | SF Symbol `checkmark.square.fill` (blue) or `square` (separator-coloured). Orange border when selected. Hatched pattern when missing. |
| `SingleValueCell` | 18pt | Secondary-styled text showing mobility grade (0-3). Orange border when selected. Hatched when missing. |
| `FurcationCell` | 18pt | N equal sub-cells, one per root, showing `FurcationClass` integer. Divided by 1pt separator lines. `HatchedPattern` fill when no furcation slot exists for the aspect. |
| `TripleValueRow` | 18pt | 3 equal cells. PD values >= 4 coloured red. Hatched when missing. |
| `BoolDotRow` | 18pt | 3 cells each with a filled (6pt) or stroked (6pt) `Circle`. Red for Bleeding, blue for Plaque. |
| `HatchedPattern` | flexible | 45 degree diagonal lines at 6pt spacing drawn via `GeometryReader`-driven `Path` over a semi-transparent `tertiarySystemBackground`. |

---

### `Views/Chart/ToothGraphicSideView.swift`

Extracted from `ToothColumnView.swift` into its own file. Handles the complex `Path` drawing for the clinical line chart embedded in each tooth column.

#### Layout constants

| Constant | Value | Meaning |
|---|---|---|
| `rootHeight` | 50pt | Coordinate space for root-level measurements (0-10mm scale) |
| `crownHeight` | 30pt | Reserved space for the crown region |
| `lineSpacing` | 5pt/mm | `rootHeight / 10` — each mm maps to 5pt of Y travel |
| Total height | 80pt | `rootHeight + crownHeight` |

A reference grid of 11 horizontal lines (0-10mm) is drawn at opacity 0.5 / lineWidth 0.5 for visual scale.

#### GM Line (red) — `createGMPath`

The gingival margin line represents the gum line relative to the CEJ:

- GM values are **negated** (`-gm[i]`) before Y mapping. Positive GM = pseudopocket (gum above CEJ) = should plot above the CEJ baseline. But SwiftUI Y increases downward, so without negation a positive GM would plot downward (i.e., look like recession). Negation corrects this to match the anatomical convention.
- 5 X-positions: left edge (blended), `w/6`, `w/2`, `5w/6`, right edge (blended).
- **Inter-tooth blending:** Left edge = average of current tooth's mesial GM and the previous tooth's distal GM. Right edge = average of current tooth's distal GM and next tooth's mesial GM. Produces a seamless continuous line across all teeth in the quadrant.
- Rendered with `.red`, lineWidth 1.5, round cap/join.

#### PD Line (blue) — `createPDPath`

The probing depth line represents the bottom of the periodontal pocket:

- Plotted at `pd[i] - gm[i]` (distance from the gingival margin down to the pocket base). The blue line always sits below the red line.
- Uses the same inter-tooth blending logic (averaging adjacent distal/mesial values for left/right edges).
- Rendered with `.blue`, lineWidth 1.5, round cap/join.

#### Mirroring

`isMirrored = true` flips the Y coordinate:
- Non-mirrored: `y = rootHeight - val * lineSpacing` (root points down, crown at top).
- Mirrored: `y = crownHeight + val * lineSpacing` (root points up, crown at bottom).

For upper jaw: outer (facial) is non-mirrored (top), inner (palatal) is mirrored (bottom). For lower jaw: reversed. This ensures roots always point toward the dental arch center, consistent with WHO charting convention.

### `ViewModels/AIVoiceViewModel.swift`

An `@MainActor` `ObservableObject` that orchestrates the voice parsing simulation and maintains the live state of the NLP pipeline.

#### State properties

| Property | Type | Role |
|---|---|---|
| `liveTranscription` | `String` | The raw incoming text stream, updated word-by-word during simulation. |
| `isListening` | `Bool` | Whether the simulation or live microphone recording is currently active. |
| `currentCommand` | `AnnotationCommand?` | The most recent command emitted by the parser for the current metric. |
| `commandHistory` | `[AnnotationCommand]` | The complete list of all applied mutations. `ChartDashboard` listens to this to rebuild the mouth. |
| `currentCursor` | `ChartingCursor?` | The current traversal position of the parser. |
| `activeSelection` | `TeethSelection?` | Any explicitly targeted out-of-sequence selection (e.g. from "BOP 16"). |
| `pendingValues` | `[String]` | Numbers buffered by the parser but not yet committed. |
| `wpm` | `Double` | Simulation playback speed (Words Per Minute). |

#### Simulation Engine

- **`startSimulation(from:)`** — Splits the input transcript (e.g., `dr_lucky_ground.txt`) into an array of words. Spawns an async `Task` that loops through the array, appending one word at a time to `liveTranscription`.
- **Parsing per word** — On every loop iteration, a fresh `VoiceCommandParser` is instantiated and runs `parse(text: liveTranscription, isFinal: false)`. The view model then copies the parser's internal state (`cursor`, `activeSelection`, `pendingValues`) into its own `@Published` properties, which drives the UI updates in `AIListeningView` and `ChartDashboard`.
- **`flushTimer`** — A 1.5-second inactivity timer. If no new words arrive (e.g. the clinician pauses dictation), the timer fires and runs `parse(text: isFinal: true)`, forcing the parser to commit any pending numeric values or boolean metrics.

---

### `Views/Voice/AIListeningView.swift`

A floating overlay panel that slides in from the trailing edge in AI Mode. It fills **40% of viewport width** and **80% of height**.

**Visual design:** `.ultraThinMaterial` background forced to `.light` color scheme, clipped to `RoundedRectangle(cornerRadius: 24)`. An orange-to-deep-orange gradient border (`LinearGradient`) pulses on a 1.5s repeating `easeInOut` animation. A soft shadow (`radius: 20, x: -10, y: 10`) creates depth.

**Three sections:**

1. **Live Transcription** — scrollable monospace `footnote`-sized `Text` showing the accumulating `liveTranscription` string. Minimum 120pt height (~5 lines).
2. **Current Command** — structured card with three rows:
   - *Operation* — `currentMetric.displayName` from the active cursor (e.g., "Probing Depth").
   - *Selection* — current tooth number from the cursor.
   - *Pending / Last Applied Values* — `HStack` of capsule-outlined value chips. Shows `pendingValues` when non-empty, otherwise the last applied command's values.
3. **History** — last 5 `AnnotationCommand` values in reverse-chronological order, each rendered as a `HistoryCard` with operation name and tooth/values.

**Simulation trigger:** A play/stop button in the header calls `viewModel.toggleSimulation(from: AIVoiceViewModel.debugTranscript)`, running the built-in debug transcript at the configured WPM.

---

### `Views/Onboarding/OnboardingView.swift` & `AnnotationVisualizerView`

A unified configuration interface for both initial onboarding and in-app settings (`isSettingsMode` flag).

#### Section 1 — Voice Sample Calibration

- Displays an Indonesian calibration sentence for the clinician to read aloud.
- Integrates with `AudioManager` to request microphone permissions, record a 16kHz WAV voice sample, and manage playback.
- `hasRecorded` flag gates the "Complete Setup" / "Save" button.

#### Section 2 — Annotation Order Configuration

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

**`AnnotationVisualizerView`** (extracted to `AnnotationVisualizerView.swift`) — a live top-down teeth preview re-rendering on every config change. Shows two `JawVisualizer` instances (upper/lower), each displaying a 16-block placeholder tooth strip flanked by traversal arrows. The step number (e.g. "1.", "2.") is computed by `ChartingConfiguration.sequenceIndex(for:aspect:)`.

**Configuration persistence:** Encoded with `JSONEncoder` and stored in `UserDefaults` under key `"ChartingConfiguration"`. Read back in `OnboardingView.onAppear` and `AIVoiceViewModel.getConfiguration()`.

---

### `Debug/SelectionDebugMenu.swift`

A developer `.sheet` exposing:

- `Slider` for `aiViewModel.wpm` (20-300 WPM) to control simulation speed.
- Pre-built highlight scenarios: "Tooth 16 Probing Depth (Outer)", "Tooth 21 Bleeding (Inner, Mid)", "Q1 Gingival Margin (Outer)", "All Implants (Shared Grid)".
- "Clear All Selections" destructive button.

Each button directly mutates `selectionModel.selectedCells`, triggering an immediate re-render of orange borders on the chart.

---

## Data Model (`Models/Models.swift`)

All chart state is expressed through a strictly typed value-type model. The single source of truth is `mouth: [Int: ToothObject]` in `ChartDashboard`, keyed by FDI tooth number.

> **After the refactor**, `Models.swift` contains only the core data types listed below. The NLP pipeline has been extracted into two dedicated files: [`VoiceTokenizer.swift`](#voicetokenizerswift) and [`VoiceCommandParser.swift`](#voicecommandparserswift).

### `ToothObject`

| Property | Type | Description |
|---|---|---|
| `toothNumber` | `Int` | FDI number (11-18, 21-28, 31-38, 41-48) |
| `probingDepth` | `AspectData<Int>` | Pocket depth in mm per site (3 sites per aspect) |
| `gingivalMargin` | `AspectData<Int>` | CEJ-to-gum distance in mm. Negative = recession, positive = pseudopocket |
| `mobility` | `MobilityClass` | Tooth mobility grade 0-3 |
| `furcation` | `FurcationData?` | `nil` for single-rooted / anterior teeth |
| `bleeding` | `AspectData<Bool>` | Bleeding on probing per site |
| `plaque` | `AspectData<Bool>` | Plaque present per site |
| `missing` | `Bool` | Edentulous site |
| `implant` | `Bool` | Osseointegrated implant present |
| `attachmentLevel` | `AspectData<Int>` *(computed)* | CAL = PD - GM, element-wise via `zip` |

### `AspectData<T>`

Generic `Equatable` container. `outer: [T]` (Facial/Buccal) and `inner: [T]` (Palatal/Lingual), each 3 elements ordered `[mesial, mid, distal]`.

### `MobilityClass` / `FurcationClass`

`Int`-backed `CaseIterable` enums ranging 0-3. `FurcationClass.zero` = no furcation involvement; `.three` = through-and-through.

### Furcation Anatomy

| Tooth | Outer roots | Inner roots | Notes |
|---|---|---|---|
| Maxillary Molars (16,17,18,26,27,28) | 1 | 2 | 3 roots total: 2 buccal + 1 palatal |
| Maxillary 1st Premolars (14,24) | 0 | 2 | 2 roots: 1 buccal + 1 palatal |
| Mandibular Molars (36-38, 46-48) | 1 | 1 | 2 roots: 1 mesial + 1 distal |
| All other teeth | — | — | `furcation = nil` |

When no furcation slot exists for an aspect, `HatchedPattern` is rendered. When `tooth.missing = true`, all data cells in the column use `HatchedPattern` and hide values.

### `ChartCellCoordinate`

A `Hashable` struct uniquely identifying any cell in the chart:

```swift
struct ChartCellCoordinate: Hashable {
    var toothNumber: Int
    var operation: AnnotationOperation
    var aspect: ChartAspect?  // nil for shared grids (Implant, Mobility)
    var siteIndex: Int?       // 0/1/2 = mesial/mid/distal. nil for single-value cells
}
```

`ChartSelectionModel` holds a `Set<ChartCellCoordinate>` of currently highlighted cells. `updateHighlight()` in `ChartDashboard` rebuilds this set on every parser state change.

### `TeethSelection`

Represents a parsed target range. `expectedSlots` is the count of `(tooth, aspect, site)` tuples from start to end (computed via `ChartAnatomyResolver.sequence`), driving how many values the parser must collect before flushing.

### `ChartAnatomyResolver`

Static utility with two key functions:

- **`resolve(anatomy:for:currentAspect:)`** — maps an `AnatomyType` token to `(ChartAspect, siteIndex)`. Handles the right-side mirror: on teeth 11-18 and 41-48, "mesial" = site index 2 (distal from chart perspective); on 21-28 and 31-38, "mesial" = site index 0. Single-sided calls like `.mesial` strictly return their precise isolated target site without affecting the opposite site.
- **`sequence(from:to:)`** — returns the contiguous `[(tooth, aspect, site)]` slice between two coordinates in canonical mouth order. Allows sequences to optionally include specific start and end site boundaries. Powers both range command parsing and highlight mask generation.

### Factory Methods

| Method | Returns |
|---|---|
| `ToothObject.create(number:)` | Zeroed tooth with anatomically correct furcation slots |
| `ToothObject.mock(number:)` | PD `[3,5,2]`, GM `[0,-2,1]`, mid bleeding site |
| `ToothObject.fullMouthMock()` | All 32 teeth with mock data |
| `ToothObject.fullMouthEmpty()` | All 32 teeth zeroed — actual startup state |

### Voice Annotation Model

```swift
struct AnnotationCommand: Equatable {
    var operation: AnnotationOperation  // probingDepth, gingivalMargin, bleeding, etc.
    var teethSelection: TeethSelection
    var aspect: ChartAspect?
    var values: [String]               // measurements as strings
}
```

---

## NLP Voice Pipeline (`NLP/`)

The pipeline is split across three dedicated files:

| File | Responsibility |
|---|---|
| `VoiceTokenizer.swift` | `ActionType`, `AnatomyType`, `VoiceToken` enums + `VoiceTokenizer` class |
| `VoiceCommandParser.swift` | `VoiceCommandParser` state machine |
| `ChartingCursor.swift` | `ChartingCursor` traversal struct (see Configuration System) |

### `VoiceTokenizer`

Single left-to-right pass converting raw text to `[VoiceToken]`.

**Token types:**

| Case | Example input | Produced token |
|---|---|---|
| `.number(Int)` | `"3"` / `"tiga"` | `.number(3)` |
| `.anatomy(AnatomyType)` | `"mesio bukal"` / `"palatal"` / `"rahang bawah"` | `.anatomy(.mesioBuccal)` |
| `.metric(AnnotationOperation)` | `"resesi"` / `"BOP"` / `"plak"` | `.metric(.gingivalMargin)` |
| `.action(ActionType)` | `"lanjut"` / `"gak ada"` / `"sampai"` | `.action(.next)` |
| `.toothIdentifier(Int)` | `"gigi 16"` or bare 2-digit number 11-98 | `.toothIdentifier(16)` |
| `.word(String)` | Unrecognised | `.word("mili")` |

**Multi-word alias handling:** Checked before single-word matching. E.g., `"gak"` + `"ada"` -> `.action(.missing)` (consumes 2 words, `i += 2`). Other pairs: `"mesio bukal"`, `"disto bukal"`, `"mesio palatal"`, `"disto palatal"`, `"mesio lingual"`, `"disto lingual"`, `"rahang atas"`, `"rahang bawah"`, `"gigi <N>"`.

**Indonesian number words:** nol(0), satu(1), dua(2), tiga(3), empat(4), lima(5), enam(6), tujuh(7), delapan(8), sembilan(9), sepuluh(10).

**Number disambiguation:** Integers 11-98 without a `"gigi"` prefix -> `.toothIdentifier`. Single-digit integers or word forms -> `.number`.

**`"lanjut"` lookahead filter:** When `"lanjut"` is followed by an aspect keyword (e.g., `"palatal"`) and the next word is *not* a tooth number, the aspect word is consumed and discarded. Prevents `"Lanjut palatal 2 2 2"` from being misread as a single palatal-site selection.

**`"minus"` handling:** `"minus"` + `.number(n)` appends `-n` to the number buffer. Enables dictation of gingival recession values.

---

### `VoiceCommandParser`

State machine called on every new word. Text is fully re-tokenized from scratch on each call.

**Internal state:**

| Field | Description |
|---|---|
| `cursor: ChartingCursor` | Current traversal position |
| `activeSelection: TeethSelection?` | Explicit range or site override; `nil` = use cursor |
| `pendingValues: [String]` | Numbers buffered but not yet committed |
| `missingTeeth: Set<Int>` | Automatically skipped during cursor advances |

#### `flushNumbers(force:)` — the core commit logic

1. If `currentNumbers.count >= targetSlots` or `force == true`, the buffer is ready to emit.
2. Single value + `targetSlots > 1` -> broadcast to fill all slots (e.g., `"2"` -> `[2,2,2]`).
3. Fewer values than slots -> pad by repeating the last value.
4. **Direction reversal:** if the configuration specifies Right-to-Left for the current jaw/aspect, reverse the values array before emission. Maps the clinician's natural dictation order to the correct anatomical site indices without requiring them to reverse.
5. Emit `AnnotationCommand`.
6. **Auto-advance mechanism:** If the active metric is `.probingDepth`, advance cursor (skipping `missingTeeth`). Modifiers like `.gingivalMargin` and `.mobility` will intentionally *not* auto-advance, keeping focus on the current tooth indefinitely to allow the clinician to add further modifiers on different aspects without the UI jumping prematurely.
7. Clear `activeSelection`.

#### Token handling rules

**`.number(n)`**
- If current metric is boolean (bleeding/plaque/implant): emit pending bool command, restore to main sequence, then append number.
- Append `n` to buffer, attempt `flushNumbers(force: false)`.

**`.toothIdentifier(tooth)`**
- Flush pending numbers.
- Lookahead for `sampai`/`hingga` to detect a range. If found, continue scanning for optional end anatomy + end tooth.
- Checks `tokens[i-1]` for a preceding anatomy token (e.g., `"mesio bukal 17"` -> `startAnatomy = .mesioBuccal`).
- Three sub-cases: (1) complete range -> full `TeethSelection`; (2) incomplete range (no end tooth yet) -> single-point selection as safe suspension; (3) point selection -> `activeSelection` on one site.

**`.metric(m)`** — Flush pending numbers, clear `activeSelection`, call `cursor.setMetric(m)`.

**`.action(.next)`** ("lanjut") — Emit pending bool if applicable, force-flush numbers, then `restoreToMainSequence()`.

**`.action(.missing)` / `.action(.missing2)`** ("gak ada" / "tidak ada") — Mark tooth missing, emit `.missing` command, advance cursor skipping any further missing teeth.

**`.action(.until/.until2)`** ("sampai" / "hingga") — Lookahead for end tooth to build `activeSelection` from cursor's current position. If end tooth not yet in stream, set `activeSelection = nil` (safe suspension, prevents stale highlights).

**`.anatomy(a)`** — For jaw tokens: `cursor.jumpTo(jaw:)`. For directional anatomies: if next token is `.toothIdentifier`, defer (anatomy consumed as `startAnatomy`); otherwise resolve to a single-site `activeSelection` on the current tooth.

**`.word("minus")` + `.number(n)`** — Append `-n`, skip both tokens.

#### Auto-Advance & State Restoration

To balance hands-free flow with precise corrections, the parser distinguishes between **in-sequence** dictation and **out-of-band** (post-targeted) corrections:

1. **Auto-Advance (`isPlainTooth`)**: The cursor automatically advances to the next tooth *only* if the current metric is `.probingDepth` and the selection is a "plain tooth" (i.e., `activeSelection` has no specific sub-aspect or site). This allows the clinician to seamlessly rattle off probing depths (e.g., `"3 2 3 ... 2 2 2"`) across the arch.
2. **Suspension & Post-Targeting**: If the clinician is charting probing depths and suddenly dictates a modifier (e.g., `"Resesi 1 mili Mesial"`), the parser treats this as an out-of-band post-target. It temporarily suspends the sequence, creates a localized `TeethSelection` for the mesial site, flushes the gingival margin value, and then automatically invokes `restoreToMainSequence()`. This restores the metric back to `.probingDepth` so the clinician can immediately resume their probing depth sequence (e.g., `"2 2 2"`) without needing to manually re-declare the metric.
3. **Anatomy Lookahead**: When encountering an anatomy token (e.g., `"Lingual"`), `resolveAnatomyWithLookahead` scans ahead in the token stream. If it finds exactly 1 or 2 numbers, it assumes the clinician is targeting a specific mid-site (site index 1). If it finds 3 numbers (e.g., `"Lingual 2 2 3"`), it infers a full-aspect target, leaving `site = nil` so the parser expects a 3-slot array.

#### Streaming / flush timer

The parser is called on every new word with the full accumulated text (stateless re-tokenization). A 1.5-second `Timer` in `AIVoiceViewModel` fires after silence, calling `parse(text:isFinal: true)` to force-flush any buffered numbers.

---

### `ChartingCursor`

Extracted into its own file (`ChartingCursor.swift`). A value-type `struct` tracking the traversal state:

```swift
struct ChartingCursor: Equatable {
    var currentTooth: Int
    var currentAspect: ChartAspect        // .outer or .inner
    var currentMetric: AnnotationOperation // default: .probingDepth
    var configuration: ChartingConfiguration
    // private: primaryIndex, secondaryIndex, sequenceIndex, currentSequence
}
```

| Method | Behaviour |
|---|---|
| `setupSequence()` | Rebuilds `currentSequence` + `currentAspect` from `primaryIndex`/`secondaryIndex` + active config. |
| `advanceToNextTooth()` | Increments `sequenceIndex`; calls `advanceToNextRow()` when sequence exhausted. |
| `syncWithSequence()` | Re-reads `currentTooth`/`currentAspect` from current sequence (called after `restoreToMainSequence()`). |
| `jumpTo(jaw:)` | Jumps `primaryIndex` to target jaw (in `jawFirst` mode), resets `secondaryIndex = 0`, calls `setupSequence()`. |
| `jumpTo(aspect:)` | Jumps `secondaryIndex` to target aspect within current jaw, recalculates sequence. |

---

## Configuration System (`Configuration/`)

`ChartingConfiguration` is a `Codable`, `Equatable` struct serialised to `UserDefaults` as JSON under key `"ChartingConfiguration"`.

> **After the refactor**, `ChartingConfiguration.swift` contains only the enums and the `ChartingConfiguration` struct. `ChartingCursor` has been extracted to its own file `ChartingCursor.swift`.

| Property | Default | Meaning |
|---|---|---|
| `primaryOrder` | `.jawFirst` | Complete one jaw at a time vs one aspect at a time |
| `jawOrder` | `[.upper, .lower]` | Which jaw is charted first |
| `upperAspectOrder` | `[.buccal, .palatal]` | Aspect order within the upper jaw |
| `lowerAspectOrder` | `[.buccal, .palatal]` | Aspect order within the lower jaw |
| `aspectOrder` | `[.buccal, .palatal]` | Aspect order in `aspectFirst` mode |
| `buccalJawOrder` | `[.upper, .lower]` | Jaw order when charting the buccal aspect first |
| `palatalJawOrder` | `[.upper, .lower]` | Jaw order when charting the palatal aspect first |
| `directionMapping` | All `.leftToRight` | Per (jaw, aspect) direction preference, keyed as `"Upper-Buccal"` etc. |

**`getSequence(for:aspect:)`** returns the ordered FDI tooth list for a jaw/aspect pair, respecting direction. E.g., Upper + Left-to-Right = `[18,17,...,11, 21,...,28]`.

**`sequenceIndex(for:aspect:)`** (extension in `OnboardingView.swift`) returns the 1-based ordinal for a (jaw, aspect) pair in the full configured traversal order — used by `AnnotationVisualizerView` for step numbering.

**`AnnotationDirection`** — `.leftToRight` or `.rightToLeft`. Affects both tooth traversal order and the value-reversal in `VoiceCommandParser.flushNumbers(force:)`.

---

## Audio Infrastructure (`Audio/AudioManager.swift`)

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

Session configured as `.playAndRecord` with `.allowBluetooth` so clinicians can record via a Bluetooth headset. Conforms to `AVAudioRecorderDelegate` and `AVAudioPlayerDelegate` to clean up state on natural completion.

---

## `TestTranscripts/dr_lucky_ground.txt`

The reference clinical dictation transcript used as `AIVoiceViewModel.debugTranscript`. A realistic full-mouth charting session in Indonesian demonstrating the full command vocabulary:

- **Tooth exclusion:** `"gigi 18 gak ada"`, `"46 tidak ada"`, `"48 gak ada"`
- **Numeric sequences:** `"2 2 2"`, `"3 4 5"`
- **Range commands:** `"resesi dari mesio bukal 17 sampai disto bukal 15 minus 1"`
- **BOP ranges:** `"BOP dari bukal 16 hingga bukal 15"`
- **Navigation:** `"Lanjut"`, `"Lanjut palatal"`, `"Lanjut 43"`
- **Jaw switching:** `"rahang bawah"`, `"Lingual"`
- **Single-site targeting:** `"16 Resesi Mesio bukal 2. Bukal 4. Disto bukal 2"`
- **Verbal numbers:** `"Resesi satu mili distal"`
- **End-range shorthand:** `"Sampai 37 2"`
- **Boolean mass-assignment:** `"Plaque pada semua gigi"`

---

## Color Semantics

All colors are system-adaptive — no manual Dark Mode handling required.

| Usage | Color |
|---|---|
| Cell backgrounds | `Color(.systemBackground)` |
| Grid hairlines & borders | `Color(.separator)` |
| Hatched pattern base | `Color(.tertiarySystemBackground)` |
| Missing tooth graphic | `Color(.tertiarySystemBackground)` |
| Normal tooth tint | `Color.blue.opacity(0.1)` |
| Gingival Margin line | `.red` |
| Bleeding dots | `.red` |
| Probing Depth >= 4mm | `.red` (in `TripleValueRow`) |
| Probing Depth line | `.blue` |
| Plaque dots + Implant icon | `.blue` |
| Active selection highlight | `Color.orange` (2pt `strokeBorder`) |
| Toolbar / nav chrome | `Color(red: 0.05, green: 0.2, blue: 0.5)` (navy) |
| AI panel border | Orange-to-deep-orange `LinearGradient` |

---

## Getting Started

### Requirements

- macOS 14+ with Xcode 15+
- Target: **iPad** simulator (layout specifically tailored for iPad — iPhone not supported)

### Steps

1. Open `PeriodontalCharting.xcodeproj` in Xcode 15+.
2. Select an iPad simulator destination (iPad Pro 12.9" recommended).
3. Build and run (`Cmd + R`).
4. The chart opens with all teeth empty (`fullMouthEmpty()`). Use the **Debug** (ladybug) toolbar button to apply test highlights or adjust simulation WPM.
5. Tap **AI Mode** to open the voice panel. Tap the play button inside to run the debug transcript simulation.
6. Toggle layout mode via the toolbar (1-col / 2-col).
7. Pinch-to-zoom to inspect fine detail; use **Reset Zoom** to return to 1x.
8. Tap **Settings** (gear) to configure traversal order and record a voice calibration sample.

### Mock Data

Run the AI simulation — `debugTranscript` populates all 32 teeth with realistic clinical data as it plays. `SelectionDebugMenu` (ladybug button) provides pre-built highlight scenarios for visual testing without the voice pipeline.

---

## Roadmap

- [x] **Full-mouth chart rendering** — all 32 teeth, 4 quadrants, WHO-standard layout.
- [x] **Custom Path rendering** — continuous GM and PD lines with inter-tooth blending and mirroring.
- [x] **Furcation modelling** — per-tooth anatomical provisioning with hatched fallback.
- [x] **Pinch-to-zoom** — `MagnificationGesture` with correct `ScrollView` frame sizing.
- [x] **Native SwiftUI refactor** — all views use semantic system colors. Zero Catalyst references.
- [x] **Navigation style** — `NavigationSplitView` with navy chrome, custom floating toolbars, adaptive sidebar toggle.
- [x] **Voice Pipeline Integration** — `AIListeningView` panel and `AIVoiceViewModel` simulate live transcription streaming.
- [x] **Onboarding & Configuration** — `OnboardingView` with audio calibration, live anatomical visualiser, and drag-and-drop traversal config.
- [x] **State Machine** — Indonesian NLP engine (`VoiceTokenizer` + `VoiceCommandParser`) parses `liveTranscription` into `AnnotationCommand` mutations with range support, verbal numbers, and sub-site targeting.
- [x] **Dynamic UI Camera & Highlighting** — dual-state highlight mask (cursor vs active selection) with `ScrollViewProxy` auto-pan and padded frame limits for free panning.
- [x] **Selection Debug Menu** — developer sheet for injecting highlight states and controlling simulation WPM.
- [ ] **Live speech-to-text integration** — connect `AudioManager` to a real-time STT backend (e.g., on-device Whisper) to replace the simulation loop.
- [ ] **Patient persistence** — CoreData or SwiftData layer for saving/loading charting sessions.
- [ ] **Export** — generate a PDF report from the live chart state.
- [ ] **iPhone / compact layout** — responsive layout fallback for smaller screens.
