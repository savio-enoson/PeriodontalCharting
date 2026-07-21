# Periodontal Charting App

A comprehensive, iPad-optimized SwiftUI application for dental professionals to efficiently record and track periodontal disease clinical parameters using real-time voice commands.

---

## Table of Contents

1. [Overview & Project Context](#overview--project-context)
2. [Architecture](#architecture)
3. [Data Model (`Models.swift`)](#data-model-modelsswift)
4. [View Layer](#view-layer)
5. [Getting Started](#getting-started)
6. [Roadmap](#roadmap)

---

## Overview & Project Context

Periodontal charting is historically a highly manual process. A practitioner must simultaneously hold clinical instruments and dictate 3–6 numeric measurements per tooth site to an assistant who enters data — a process prone to transcription errors and inefficiency.

This project modernizes the workflow in two phases:

1. **Phase 1 (Complete):** A WHO-standard, visually dense clinical chart that renders a full 32-tooth mouth across four quadrants. The chart scales seamlessly on iPad, supporting pinch-to-zoom and a 1-column vs 2-column layout toggle.

2. **Phase 2 (In Progress):** A real-time voice-transcription pipeline that converts clinical dictation (e.g., *"tooth 16 probing depth 4 5 3 4 5 3"*) into structured `AnnotationCommand` mutations, enabling completely hands-free charting.

### Key Design Principles

- **Clinical accuracy over aesthetics:** Every rendering decision (line direction, GM sign convention, mirroring logic) follows WHO and standard periodontal charting conventions.
- **Visually dense:** The chart fits all 32 teeth with full data grids on a single iPad screen, favouring legibility of numbers over whitespace.
- **Native SwiftUI:** No third-party design system dependency. All styling uses semantic SwiftUI colors and adaptive system fonts so Dark Mode, Dynamic Type, and accessibility work out of the box.

---

## Architecture

The application uses a modern, declarative SwiftUI component hierarchy. State flows top-down from the root `ChartDashboard` into individual `ToothColumnView` instances, which are read-only consumers of the `mouth` dictionary.

```
PeriodontalChartingApp
└── ContentView
    └── ChartDashboard          ← root state owner + toolbar
        ├── QuadrantView (Q1 – Upper Right)
        │   ├── SideLabelsView
        │   └── ToothColumnView × 8
        │       ├── aspectGrid (Facial / outer)
        │       │   ├── ImplantCheckCell
        │       │   ├── SingleValueCell    (Mobility)
        │       │   ├── FurcationCell
        │       │   ├── TripleValueRow × 3 (GM, PD, CAL)
        │       │   └── BoolDotRow × 2     (Bleeding, Plaque)
        │       ├── toothGraphic
        │       │   ├── ToothGraphicSideView (outer)
        │       │   └── ToothGraphicSideView (inner, mirrored)
        │       └── aspectGrid (Palatal / inner)
        ├── QuadrantView (Q2 – Upper Left)
        ├── QuadrantView (Q4 – Lower Right)
        └── QuadrantView (Q3 – Lower Left)
```

### `PeriodontalChartingApp.swift`

The `@main` entry point. A minimal `WindowGroup` wrapping `ContentView` — no environment injections required.

### `ContentView.swift`

Serves as the root layout shell, utilizing a native iPadOS `NavigationSplitView` to present a patient record list in the sidebar alongside the main `ChartDashboard` in the detail pane. It applies the app's signature navy blue styling theme across the navigation chrome.

### `ChartDashboard.swift`

The **root interactive viewport** and sole owner of global chart state. It implements a custom, solid-navy floating toolbar nestled seamlessly below the top safe area.

| Responsibility | Implementation |
|---|---|
| Holds `@State private var mouth: [Int: ToothObject]` | Populated via `ToothObject.fullMouthMock()` |
| Floating Toolbar | Custom `.overlay` floating in the top trailing edge holding all chart actions. |
| AI Voice Mode | Toggles a sliding `AIListeningView` overlay from the right edge. |
| Sidebar Toggle | Custom floating button mapped to `NavigationSplitViewVisibility` to recover the sidebar when dismissed. |
| Layout toggling (1-col / 2-col) | `@State private var isSingleColumn` + toolbar `Button` |
| Pinch-to-zoom | `MagnificationGesture` accumulated into `finalScale * currentScale` |
| Scroll viewport | `ScrollView([.horizontal, .vertical])` containing the full `scaleEffect`-scaled content |
| Frame tracking for scroll sizing | `GeometryReader` + `baseSize` state to dynamically grow the `ScrollView`'s content frame |

**Zoom implementation detail:** Because `scaleEffect` scales the visual but not the layout frame, `ChartDashboard` reads the pre-scale `baseSize` via a `GeometryReader` overlay and manually sets the `frame` to `baseSize * scale`. This is required for `ScrollView` to expose correct scroll extents after zooming.

**FDI quadrant order:** The FDI numbering system is preserved:
- Q1: teeth `[18,17,16,15,14,13,12,11]` — upper right, rendered left-to-right from the chart's perspective (reversed anatomically)
- Q2: teeth `[21,22,23,24,25,26,27,28]` — upper left
- Q4: teeth `[48,47,46,45,44,43,42,41]` — lower right
- Q3: teeth `[31,32,33,34,35,36,37,38]` — lower left

### `QuadrantView.swift`

Renders one dental quadrant. Responsible for:
- Displaying the quadrant title (e.g. "Quadrant 1 (Upper Right)") and aspect labels ("Outer (Facial)" / "Inner (Palatal/Lingual)").
- Rendering the `SideLabelsView` on the appropriate side (left or right depending on the quadrant's position in the 2-column layout), separated by a native `Divider()`.
- Laying out 8 `ToothColumnView` instances in a horizontal row with zero spacing so grid lines merge.

**`SideLabelsView`:** Renders a fixed-width (110pt) panel of row labels aligned to the tooth column rows. The layout structure matches the column views:
- **Shared Grid Labels:** Implant and Mobility labels are always rendered at the top, just below the tooth number.
- **Visual Separator:** A 2pt double-spacing separates the shared grid from the aspect-specific grids.
- **Aspect Grids & Graphic:** The aspect grid labels (Furcation, GM, PD, CAL, Bleeding, Plaque) are rendered above and below the central `graphicPlaceholder`.

### `ToothColumnView.swift`

The **core rendering engine** for a single tooth column. Fixed to 60pt width. It composes four logical sub-sections:

1. **Tooth number header** — a 24pt tall `Text` showing the FDI number (e.g. "16").
2. **`sharedGrid`** — Implant and Mobility values, which are shared properties for the tooth rather than specific to an aspect. These are positioned at the top of the column.
3. **`aspectGrid`** — renders the full data grid for one aspect (outer or inner). Placed above and below the graphic. Contains dedicated sub-view structs (see [Row Types](#row-types-in-toothcolumnview) below).
4. **`toothGraphic`** — two stacked `ToothGraphicSideView` instances, one for each aspect.

**Grid line approach:** Each cell is a `ZStack` containing a `Color(.systemBackground)` fill. The `VStack(spacing: 1)` between rows creates 1pt gaps that are filled by the parent `background(Color(.separator))`, achieving a hairline grid effect. A `Divider()` is overlaid on the trailing edge of each column (except the last). A wider 2pt gap is used between the `sharedGrid` and the top `aspectGrid` to serve as a clear visual separator.

### `ToothGraphicSideView.swift`

Handles the complex `Path` drawing for the clinical line chart embedded in each tooth's graphic area.

**Layout constants:**
- `rootHeight = 50pt`: The coordinate space for root-level measurements (0–10mm scale).
- `crownHeight = 30pt`: Reserved space at the top (or bottom when mirrored) for crown anatomy.
- `lineSpacing = rootHeight / 10 = 5pt per mm` of probing depth / gingival margin.

**Reference grid lines:** 11 horizontal lines (0–10) are drawn in the root region to provide visual reference for PD values. Their Y-positions flip based on `isMirrored`.

**GM Line (`createGMPath`):**
- Maps `gingivalMargin` values to Y-coordinates. Signs are negated because positive GM = recession = root exposed = plotted downward from the CEJ.
- Bridges seamlessly to adjacent teeth by computing the average of the shared interproximal point between this tooth's distal value and the neighbour's mesial value.
- 5 points total: `x=0` (left edge, blended), `x=w/6`, `x=w/2`, `x=5w/6`, `x=w` (right edge, blended).
- Rendered in `.red`.

**PD Line (`createPDPath`):**
- Maps `probingDepth - gingivalMargin` (distance from GM to the pocket base) to Y-coordinates.
- Uses the same inter-tooth blending logic as the GM line.
- Rendered in `.blue`.

**Mirroring:** For inner-aspect views, `isMirrored = true` flips the coordinate system vertically. This ensures roots point upward for maxillary teeth (outer aspect at top) and downward for mandibular teeth (outer aspect at bottom), consistent with WHO charting convention.

### `AIListeningView.swift`

A foundational overlay component for the upcoming voice annotation feature. It uses an `.ultraThinMaterial` background with a vibrant orange-to-deep-orange gradient strobing border. It is broken into three distinct sections:
- **Live Transcription**: A monospace readout of the clinician's dictated commands.
- **Current Command**: A structured card representing the actively parsed operation, tooth selection, and values.
- **History**: A scrollable history feed of recently processed commands.

### `OnboardingView.swift` & `AnnotationVisualizerView`

A unified configuration interface serving as both the initial onboarding flow and the in-app settings modal. It features:
- **Voice Calibration**: Integrates with `AudioManager` to request microphone permissions, record a 16kHz WAV voice sample, and manage playback.
- **Annotation Order Configuration**: A deeply customized nested UI for defining charting traversal rules (e.g., Upper Jaw first vs Outer Aspect first). 
- **Custom Drag Engine (`TwoItemReorderable`)**: Bypasses standard SwiftUI `onDrag` limitations (which enforce long-press delays and use translucent snapshots) with a custom `DragGesture` engine. This enables zero-delay, true physical dragging of entire configuration cards.
- **Live Visualizer**: A dynamic top-down teeth placeholder graphic (`AnnotationVisualizerView`) that reacts in real-time to configuration changes, mapping anatomical aspects (Outer/Inner) to traversal arrows.

### `AudioManager.swift`

An `@ObservableObject` singleton responsible for `AVFoundation` interactions. It manages `AVAudioSession` configuration, requests `NSMicrophoneUsageDescription` permissions, and handles recording/playback state of 16kHz WAV files for voice pipeline calibration.

### `ChartingConfiguration.swift`

The serializable data model defining the clinician's preferred traversal sequence. It tracks the primary grouping (`jawFirst` vs `aspectFirst`), the nested order arrays (e.g. `jawOrder`, `upperAspectOrder`), and the direction (`Left to Right` vs `Right to Left`) for each anatomical side.

### `ViewModels/AIVoiceViewModel.swift`

Manages the state for the voice UI overlay and currently hosts the mock data for the simulation.
- **`liveTranscription`**: The active text buffer displayed in the UI.
- **`isListening`**: Toggles the recording state and visualizer animations.
- **`simulateTranscription()`**: Emulates real-time voice input by incrementally appending words from a hardcoded transcript (e.g., `dr_lucky_ground.txt`) at a configurable Words-Per-Minute (WPM) rate.

### NLP Parsing Architecture (Upcoming)

The core challenge of Phase 2 is converting unstructured, domain-specific Indonesian natural language into precise data mutations. The proposed solution is a **State-Driven Rule-Based Parser** consisting of:

1. **Tokenizer**: Converts text chunks into domain-specific tokens (e.g., "mesio bukal" -> `.site(.mesioBuccal)`, "gak ada" -> `.action(.missing)`, "2" -> `.number(2)`).
2. **Virtual Cursor (`ChartingCursor`)**: Tracks the implicit state of the clinician (Current Tooth, Current Aspect, Current Metric). It follows the traversal sequence defined in `ChartingConfiguration`.
3. **Pattern Matcher**: Reads the token stream and applies semantic rules:
   - *Implicit triad*: `[.number(3), .number(4), .number(3)]` -> Emits an `AnnotationCommand` for the current metric (default: Probing Depth) and advances the cursor to the next tooth.
   - *Explicit navigation*: `[.action(.lanjut), .anatomy(.palatal)]` -> Shifts the cursor to the palatal aspect of the current jaw.
   - *Ranged application*: `[.metric(.bop), .action(.dari), .anatomy(...), .action(.sampai), .anatomy(...)]` -> Applies a boolean flag across a continuous range of teeth sites.

---

## Data Model (`Models.swift`)

All chart state is expressed through a strictly typed value-type model. The single source of truth is `mouth: [Int: ToothObject]` in `ChartDashboard`, keyed by FDI tooth number.

### `ToothObject`

| Property | Type | Description |
|---|---|---|
| `toothNumber` | `Int` | FDI number (11–18, 21–28, 31–38, 41–48) |
| `probingDepth` | `AspectData<Int>` | Pocket depth in mm per site (3 sites per aspect) |
| `gingivalMargin` | `AspectData<Int>` | Distance from CEJ to gingival margin in mm. Negative = recession, positive = pseudopocket |
| `mobility` | `MobilityClass` | Tooth mobility grade 0–3 |
| `furcation` | `FurcationData?` | `nil` for anterior/single-rooted teeth |
| `bleeding` | `AspectData<Bool>` | Bleeding on probing per site |
| `plaque` | `AspectData<Bool>` | Plaque present per site |
| `missing` | `Bool` | Tooth is absent (edentulous site) |
| `implant` | `Bool` | Osseointegrated implant present |
| `attachmentLevel` | `AspectData<Int>` *(computed)* | CAL = PD − GM per site |

### `AspectData<T>`

A generic container holding `outer: [T]` (Facial/Buccal) and `inner: [T]` (Palatal/Lingual) arrays, each with 3 elements ordered `[mesial, mid, distal]`.

### Complex Anatomical Modeling (Furcation)

Furcation involvement depends on root anatomy and varies by tooth type:

| Tooth | Outer roots | Inner roots | Notes |
|---|---|---|---|
| Maxillary Molars (16,17,18,26,27,28) | 1 | 2 | 3 roots total: 1 palatal, 2 buccal |
| Maxillary 1st Premolars (14,24) | 0 | 2 | 2 roots: 1 buccal, 1 palatal |
| Mandibular Molars (36–38, 46–48) | 1 | 1 | 2 roots: 1 mesial, 1 distal |
| All other teeth | — | — | `furcation = nil` |

When a `furcation` slot exists, its `FurcationClass` grade (0–3) is shown as a numeric cell. When a tooth has no furcation for a given aspect, a **diagonal hatched pattern** (`HatchedPattern`) is rendered as a visual fallback to indicate "not applicable."

### Voice Annotation Model

The voice pipeline will produce `AnnotationCommand` values that mutate `mouth`:

```swift
struct AnnotationCommand {
    var operation: AnnotationOperation   // e.g. .probingDepth, .gingivalMargin
    var teethSelection: TeethSelection   // target tooth range
    var values: [Int]                    // parsed measurement values
}
```

`AnnotationOperation` covers all chartable parameters: `probingDepth`, `gingivalMargin`, `mobility`, `furcation`, `bleeding`, `plaque`, `missing`, `implant`.

### Factory Methods

- **`ToothObject.create(number:)`** — provisions a zeroed tooth with correct furcation slots for the given FDI number.
- **`ToothObject.mock(number:)`** — returns a pre-filled tooth (PD: `[3,5,2]`, GM: `[0,-2,1]`, one bleeding site) for UI development.
- **`ToothObject.fullMouthMock()`** — builds the complete `[Int: ToothObject]` dictionary for all 32 teeth.

---

## View Layer

### Row Types in `ToothColumnView`

Each row type is implemented as a dedicated `private struct` for independent previewability and clean separation of concerns.

| Struct | Height | Contents |
|---|---|---|
| `ImplantCheckCell` | 18pt | System checkbox icon for the `implant` flag. Blue fill when checked. |
| `SingleValueCell` | 18pt | Plain secondary-styled text for `mobility` grade. |
| `FurcationCell` | 18pt | N subdivided cells for each furcation site, or `HatchedPattern` if not applicable. |
| `TripleValueRow` | 18pt | 3 equal cells for Gingival Margin, Probing Depth, or CAL numeric values. |
| `BoolDotRow` | 18pt | 3 filled/unfilled `Circle` dots. Red for Bleeding, blue for Plaque. |

### `HatchedPattern`

A standalone `View` drawing 45° diagonal lines using a `GeometryReader`-driven `Path` over a `Color(.tertiarySystemBackground)` base. Used wherever a furcation slot does not exist for a given tooth/aspect combination.

### Color Semantics

All colors are system-adaptive — no manual Dark Mode handling is required.

| Usage | Color |
|---|---|
| Cell backgrounds | `Color(.systemBackground)` |
| Grid hairlines & borders | `Color(.separator)` |
| Hatched pattern base | `Color(.tertiarySystemBackground)` |
| Missing tooth graphic | `Color(.tertiarySystemBackground)` |
| Normal tooth tint | `Color.blue.opacity(0.1)` |
| Gingival Margin line | `.red` |
| Bleeding dots | `.red` |
| Probing Depth line | `.blue` |
| Plaque dots + Implant icon | `.blue` |

---

## Getting Started

### Requirements

- macOS 14+ with Xcode 15+
- Target: **iPad** simulator (the layout is specifically tailored for iPad screen dimensions — iPhone is not supported)

### Steps

1. Open `PeriodontalCharting.xcodeproj` in Xcode 15+.
2. Select an **iPad** simulator destination.
3. Build and run (`Cmd + R`).
4. Toggle layout mode (1-col / 2-col) via the toolbar.
5. Use pinch-to-zoom gestures to inspect fine detail, and the "Reset Zoom" toolbar button to return to 1×.

### Mock Data

The app launches with `ToothObject.fullMouthMock()` pre-loaded, giving every tooth a probing depth of `[3,5,2]`, a gingival margin of `[0,-2,1]`, and one bleeding site. This allows immediate visual verification of the Path rendering, grid layout, and furcation patterns without any backend connection.

---

## Roadmap

- [x] **Full-mouth chart rendering** — all 32 teeth, 4 quadrants, WHO-standard layout.
- [x] **Custom Path rendering** — continuous Gingival Margin and Probing Depth lines with inter-tooth blending and mirroring.
- [x] **Furcation modeling** — per-tooth anatomical provisioning with hatched fallback.
- [x] **Pinch-to-zoom** — `MagnificationGesture` with correct `ScrollView` frame sizing.
- [x] **Catalyst → Native SwiftUI refactor** — removed all 12 Catalyst files; all views use semantic system colors, `Divider()`, `.foregroundStyle`, and `.background(.background)`. Zero Catalyst references remain.
- [x] **Navigation style** — Introduced a customized `NavigationSplitView` with solid navy styling, custom floating toolbars, and adaptive sidebar toggle controls.
- [x] **Voice Pipeline Integration:** Added the `AIListeningView` UI panel and established the `AIVoiceViewModel` architecture to simulate live, real-time transcription streaming.
- [x] **Onboarding & Configuration:** Built a custom Settings modal (`OnboardingView`) with audio calibration, a dynamic anatomical visualizer, and a high-performance drag-and-drop engine for configuring annotation traversal rules (`ChartingConfiguration`).
- [ ] **State Machine:** Implement the Indonesian NLP Regex engine inside `VoiceCommandParser` to parse the `AIVoiceViewModel.liveTranscription` stream into discrete `AnnotationCommand` data mutations on `mouth`.
- [ ] **Patient persistence:** CoreData or SwiftData layer for saving/loading charting sessions.
- [ ] **Export:** Generate a PDF report from the live chart state.
