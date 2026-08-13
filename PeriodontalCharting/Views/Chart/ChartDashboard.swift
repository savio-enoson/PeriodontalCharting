import SwiftUI
import SwiftData
import Combine
import UIKit

struct ChartContentView: View, Equatable {
    var isSingleColumn: Bool
    var mouth: [Int: ToothObject]
    var updateTooth: (ToothObject) -> Void
    
    static func == (lhs: ChartContentView, rhs: ChartContentView) -> Bool {
        return lhs.isSingleColumn == rhs.isSingleColumn && lhs.mouth == rhs.mouth
    }
    
    private var q1: [ToothObject] { [18,17,16,15,14,13,12,11].compactMap { mouth[$0] } }
    private var q2: [ToothObject] { [21,22,23,24,25,26,27,28].compactMap { mouth[$0] } }
    private var q4: [ToothObject] { [48,47,46,45,44,43,42,41].compactMap { mouth[$0] } }
    private var q3: [ToothObject] { [31,32,33,34,35,36,37,38].compactMap { mouth[$0] } }
    
    var body: some View {
        VStack(spacing: 40) {
            if isSingleColumn {
                QuadrantView(title: "Quadrant 1 (Upper Right)", teeth: q1, isUpperJaw: true,  showLeftLabels: true,  showRightLabels: false, onToothUpdate: updateTooth)
                QuadrantView(title: "Quadrant 2 (Upper Left)",  teeth: q2, isUpperJaw: true,  showLeftLabels: true,  showRightLabels: false, onToothUpdate: updateTooth)
                QuadrantView(title: "Quadrant 4 (Lower Right)", teeth: q4, isUpperJaw: false, showLeftLabels: true,  showRightLabels: false, onToothUpdate: updateTooth)
                QuadrantView(title: "Quadrant 3 (Lower Left)",  teeth: q3, isUpperJaw: false, showLeftLabels: true,  showRightLabels: false, onToothUpdate: updateTooth)
            } else {
                // Upper Jaw
                HStack(alignment: .top, spacing: 24) {
                    QuadrantView(title: "Quadrant 1 (Upper Right)", teeth: q1, isUpperJaw: true, showLeftLabels: true,  showRightLabels: false, onToothUpdate: updateTooth)
                    QuadrantView(title: "Quadrant 2 (Upper Left)",  teeth: q2, isUpperJaw: true, showLeftLabels: false, showRightLabels: true, onToothUpdate: updateTooth)
                }
                // Lower Jaw
                HStack(alignment: .top, spacing: 24) {
                    QuadrantView(title: "Quadrant 4 (Lower Right)", teeth: q4, isUpperJaw: false, showLeftLabels: true,  showRightLabels: false, onToothUpdate: updateTooth)
                    QuadrantView(title: "Quadrant 3 (Lower Left)",  teeth: q3, isUpperJaw: false, showLeftLabels: false, showRightLabels: true, onToothUpdate: updateTooth)
                }
            }
        }
        .padding(24)
        .padding(.top, 70) // Push content down to avoid overlapping with floating toolbar
    }
}

struct ChartDashboard: View {
    /// The persisted chart being edited. `nil` when no record is selected.
    var chart: PatientChart?
    @Environment(\.modelContext) private var modelContext

    @State private var mouth: [Int: ToothObject] = ToothObject.fullMouthEmpty()
    @State private var isSingleColumn = false
    @State private var saveConfirmation = false
    @StateObject private var selectionModel = ChartSelectionModel()
    @State private var zoomScale: CGFloat = 1.0
    @State private var targetRect: CGRect? = nil
    @State private var toothFrames: [Int: CGRect] = [:]
    @StateObject private var aiViewModel = AIVoiceViewModel()
    @State private var showDebugMenu = false
    @State private var showAIMode = false
    @State private var showSettings = false
    @State private var showZoomSlider = false
    @State private var show3DView = false
    @State private var exportURL: URL?
    @State private var showExportOptions = false
    @State private var isExporting = false
    @State private var highlightTask: Task<Void, Never>?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        ZoomableScrollView(zoomScale: $zoomScale, targetRect: $targetRect, showAIMode: showAIMode) {
            ChartContentView(isSingleColumn: isSingleColumn, mouth: mouth, updateTooth: updateTooth)
                .equatable()
                .coordinateSpace(name: "ChartSpace")
                .onPreferenceChange(HighlightFramePreferenceKey.self) { frame in
                    if let f = frame {
                        self.targetRect = f
                    }
                }
                .onPreferenceChange(ToothFramePreferenceKey.self) { frames in
                    self.toothFrames = frames
                }
                // ZoomableScrollView hosts this content in a nested UIHostingController,
                // which does NOT inherit environmentObjects from the outer SwiftUI
                // hierarchy. Inject here so ToothColumnView can read selectionModel.
                .environmentObject(selectionModel)
        }
        .onChange(of: showAIMode) { _, newValue in
            if newValue {
                DispatchQueue.main.async {
                    aiViewModel.initializeCursorIfNeeded()
                }
            }
        }
        .background(.background)
        .overlay(alignment: .topTrailing) {
            let darkBlue = Color(red: 0.05, green: 0.2, blue: 0.5)
            HStack(spacing: 20) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showAIMode.toggle()
                        if showAIMode {
                            columnVisibility = .detailOnly
                        }
                    }
                } label: {
                    Label("AI Mode", systemImage: "apple.intelligence")
                }
                
                Button {
                    withAnimation { isSingleColumn.toggle() }
                } label: {
                    Label(
                        isSingleColumn ? "2 Columns" : "1 Column",
                        systemImage: isSingleColumn ? "rectangle.split.2x2" : "rectangle.split.1x2"
                    )
                }

                Button {
                    show3DView = true
                } label: {
                    Label("", systemImage: "view.3d")
                }
                
                Button {
                    withAnimation { showZoomSlider.toggle() }
                } label: {
                    Label("Zoom", systemImage: "magnifyingglass")
                }
                
                Button {
                    showDebugMenu = true
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
                Button {
                    saveChart()
                } label: {
                    Label(saveConfirmation ? "Saved" : "Save",
                          systemImage: saveConfirmation ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .disabled(chart == nil)

                Button {
                    showExportOptions = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)

                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(darkBlue, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.1), radius: 10, y: 4)
            .padding(.top, 0) // align perfectly with the sidebar's navigation bar
            .padding(.trailing, 24)
        }
        .overlay(alignment: .topLeading) {
            if columnVisibility != .all {
                Button {
                    withAnimation { columnVisibility = .all }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color(red: 0.05, green: 0.2, blue: 0.5), in: Circle())
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                }
                .padding(.top, 0) // align perfectly with the safe area top
                .padding(.leading, 24)
            }
        }
        .overlay(alignment: .trailing) {
            if showAIMode {
                GeometryReader { geo in
                    HStack {
                        Spacer()
                        AIListeningView(viewModel: aiViewModel)
                            .frame(width: geo.size.width * 0.4, height: geo.size.height * 0.8)
                            .padding(.trailing, 24)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !showAIMode && showZoomSlider {
                GeometryReader { geo in
                    let trackLength = max(100, (geo.size.height / 2.0) - 100) // Half the screen minus button/padding space
                    
                    VStack(spacing: 8) {
                        Button {
                            withAnimation { zoomScale = min(zoomScale + 0.25, 3.0) }
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .font(.title3)
                        .foregroundStyle(.white)

                        Slider(value: $zoomScale, in: 1.0...3.0)
                            .tint(.white)
                            .environment(\.colorScheme, .dark)
                            .frame(width: trackLength)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 44, height: trackLength) // Constrain the layout bounding box width after rotation

                        Button {
                            withAnimation { zoomScale = max(zoomScale - 0.25, 1.0) }
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .font(.title3)
                        .foregroundStyle(.white)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 12)
                    .background(Color(red: 0.05, green: 0.2, blue: 0.5), in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                    .position(x: geo.size.width - 60, y: geo.size.height - (trackLength / 2.0) - 60)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .environmentObject(selectionModel)
        .sheet(isPresented: $showDebugMenu) {
            SelectionDebugMenu(mouth: $mouth)
                .environmentObject(selectionModel)
                .environmentObject(aiViewModel)
        }
        .sheet(isPresented: $showSettings) {
            OnboardingView(hasCompletedOnboarding: .constant(true), isSettingsMode: true)
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])   // UIActivityViewController wrapper
        }
        .confirmationDialog("Export", isPresented: $showExportOptions, titleVisibility: .visible) {
            Button("Chart (PDF)") { exportURL = exportPDF() }
            Button("3D Model (OBJ)") { exportModel(.obj) }
            Button("3D Model (STL)") { exportModel(.stl) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose what to export")
        }
        .overlay {
            if isExporting {
                ProgressView("Preparing 3D model…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fullScreenCover(isPresented: $show3DView) {
            PeriodontalAnatomyPresenter(mouth: mouth)
        }
        .onChange(of: aiViewModel.commandHistory) { _, _ in recomputeChart() }
        .onChange(of: aiViewModel.committedCommands) { _, _ in recomputeChart() }
        .onChange(of: aiViewModel.currentCursor) { _, _ in updateHighlight() }
        .onChange(of: aiViewModel.activeSelection) { _, _ in updateHighlight() }
        .onAppear { loadChart() }
    }

    /// Load the selected chart's stored mouth into local editing state. The
    /// parent re-inits this view via `.id(...)` whenever the selection changes,
    /// so `.onAppear` fires for each distinct chart.
    private func loadChart() {
        if let chart {
            mouth = chart.mouth
        }
    }

    private func saveChart() {
        guard let chart else { return }
        chart.mouth = mouth
        try? modelContext.save()

        withAnimation { saveConfirmation = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { saveConfirmation = false }
        }
    }

    private func updateTooth(_ tooth: ToothObject) {
        mouth[tooth.toothNumber] = tooth
    }
    
    private func recomputeChart() {
        var previewMouth = ToothObject.fullMouthEmpty()
        for cmd in aiViewModel.commandHistory {
            ChartProcessor.apply(command: cmd, to: &previewMouth)
        }
        self.mouth = previewMouth
    }
    
    private func updateHighlight() {
        guard let cursor = aiViewModel.currentCursor else { return }
        var newSelection = Set<ChartCellCoordinate>()
        
        if let ts = aiViewModel.activeSelection,
           let sAspect = ts.startAspect, let eAspect = ts.endAspect {
            
            let seq = ChartAnatomyResolver.sequence(from: (ts.startTooth.toothNumber, sAspect, ts.startSite),
                                                    to: (ts.endTooth.toothNumber, eAspect, ts.endSite))
            
            for (t, aspect, site) in seq {
                newSelection.insert(ChartCellCoordinate(
                    toothNumber: t,
                    operation: cursor.currentMetric,
                    aspect: aspect,
                    siteIndex: site
                ))
            }
        } else {
            for site in 0..<3 {
                newSelection.insert(ChartCellCoordinate(
                    toothNumber: cursor.currentTooth,
                    operation: cursor.currentMetric,
                    aspect: cursor.currentAspect,
                    siteIndex: site
                ))
            }
        }
        
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.selectionModel.selectedCells = newSelection
            }
        }
    }
    
    private func exportPDF() -> URL? {
        // Always render the 2-column layout at full content size,
        // ignoring the on-screen zoom/scroll state.
        let content = ChartContentView(
            isSingleColumn: false,
            mouth: mouth,
            updateTooth: { _ in }          // no-op; static render
        )
        .environmentObject(selectionModel) // ToothColumnView needs this
        .background(Color(.systemBackground))

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = .unspecified   // take natural size
        renderer.scale = UIScreen.main.scale

        var pdfURL: URL?
        renderer.render { size, renderInContext in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PeriodontalChart.pdf")
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            renderInContext(ctx)   // vector, not a bitmap
            ctx.endPDFPage()
            ctx.closePDF()
            pdfURL = url
        }
        return pdfURL
    }

    /// Rebuild the 3-D anatomy from the current chart and export it as OBJ/STL.
    /// The asset load is async, so this runs off the button tap and flips
    /// `isExporting` to show a spinner until the share sheet is ready.
    private func exportModel(_ format: Model3DFormat) {
        isExporting = true
        Task { @MainActor in
            let url = await Model3DExporter.export(mouth: mouth, format: format)
            isExporting = false
            exportURL = url
        }
    }
}

/// Lets a `URL` drive `.sheet(item:)`, which requires an `Identifiable` item.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Thin wrapper around `UIActivityViewController` so a file URL can be shared/exported.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
