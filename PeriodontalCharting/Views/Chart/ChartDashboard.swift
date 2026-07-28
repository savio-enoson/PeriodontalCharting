import SwiftUI
import Combine

class ZoomController: ObservableObject {
    @Published var currentScale: CGFloat = 1.0
    @Published var finalScale: CGFloat = 1.0
    
    func reset() {
        withAnimation {
            currentScale = 1.0
            finalScale = 1.0
        }
    }
    
    func setAIScale(_ isAI: Bool) {
        withAnimation(.easeInOut(duration: 0.5)) {
            finalScale = isAI ? 1.75 : 1.0
        }
    }
}

struct ZoomableContainer<Content: View>: View {
    @ObservedObject var zoomController: ZoomController
    var isSingleColumn: Bool
    var showAIMode: Bool
    @ViewBuilder var content: () -> Content
    
    @State private var baseSize: CGSize = .zero
    
    var body: some View {
        let scale = zoomController.finalScale * zoomController.currentScale * (isSingleColumn ? 1.35 : 1.0)
        
        content()
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { baseSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in
                            if baseSize != newSize {
                                DispatchQueue.main.async { baseSize = newSize }
                            }
                        }
                }
            )
            .scaleEffect(scale)
            .frame(
                width:  baseSize == .zero ? nil : baseSize.width  * scale + (showAIMode ? 1000 : 0),
                height: baseSize == .zero ? nil : baseSize.height * scale + (showAIMode ? 1000 : 0)
            )
    }
}

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
    @State private var mouth: [Int: ToothObject] = ToothObject.fullMouthEmpty()
    @State private var isSingleColumn = false
    @StateObject private var zoomController = ZoomController()
    @StateObject private var selectionModel = ChartSelectionModel()
    @StateObject private var aiViewModel = AIVoiceViewModel()
    @State private var showDebugMenu = false
    @State private var showAIMode = false
    @State private var showSettings = false
    @State private var highlightTask: Task<Void, Never>?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZoomableContainer(zoomController: zoomController, isSingleColumn: isSingleColumn, showAIMode: showAIMode) {
                    ChartContentView(isSingleColumn: isSingleColumn, mouth: mouth, updateTooth: updateTooth)
                        .equatable()
                }
            }
            .onChange(of: showAIMode) { _, newValue in
                if newValue {
                    aiViewModel.initializeCursorIfNeeded()
                    zoomController.setAIScale(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let selTooth = aiViewModel.activeSelection?.startTooth.toothNumber
                        let curTooth = aiViewModel.currentCursor?.currentTooth
                        if let t = selTooth ?? curTooth {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                proxy.scrollTo(t, anchor: UnitPoint(x: 0.3, y: 0.5))
                            }
                        }
                    }
                } else {
                    zoomController.setAIScale(false)
                }
            }
            .onChange(of: aiViewModel.currentCursor) { _, cur in
                if showAIMode {
                    if aiViewModel.activeSelection == nil, let cur = cur {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(cur.currentTooth, anchor: UnitPoint(x: 0.3, y: 0.5))
                        }
                    }
                }
            }
            .onChange(of: aiViewModel.activeSelection) { _, sel in
                if showAIMode {
                    if let sel = sel {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(sel.startTooth.toothNumber, anchor: UnitPoint(x: 0.3, y: 0.5))
                        }
                    } else if let cur = aiViewModel.currentCursor {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(cur.currentTooth, anchor: UnitPoint(x: 0.3, y: 0.5))
                        }
                    }
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
                    zoomController.reset()
                } label: {
                    Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                }
                
                Button {
                    showDebugMenu = true
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
                
                Button {
                    // Export logic placeholder
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                
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
            if !showAIMode {
                GeometryReader { geo in
                    let trackLength = max(100, (geo.size.height / 2.0) - 100) // Half the screen minus button/padding space
                    
                    VStack(spacing: 8) {
                        Button {
                            withAnimation { zoomController.finalScale = min(zoomController.finalScale + 0.25, 3.0) }
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .font(.title3)
                        .foregroundStyle(.white)

                        Slider(value: $zoomController.finalScale, in: 1.0...3.0)
                            .tint(.white)
                            .environment(\.colorScheme, .dark)
                            .frame(width: trackLength)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 44, height: trackLength) // Constrain the layout bounding box width after rotation

                        Button {
                            withAnimation { zoomController.finalScale = max(zoomController.finalScale - 0.25, 1.0) }
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .environmentObject(selectionModel)
        .sheet(isPresented: $showDebugMenu) {
            SelectionDebugMenu()
                .environmentObject(selectionModel)
                .environmentObject(aiViewModel)
        }
        .sheet(isPresented: $showSettings) {
            OnboardingView(hasCompletedOnboarding: .constant(true), isSettingsMode: true)
        }
        .onChange(of: aiViewModel.commandHistory) { _, newHistory in
            var newMouth = ToothObject.fullMouthEmpty()
            for cmd in newHistory {
                ChartProcessor.apply(command: cmd, to: &newMouth)
            }
            self.mouth = newMouth
        }
        .onChange(of: aiViewModel.currentCursor) { _, _ in updateHighlight() }
        .onChange(of: aiViewModel.activeSelection) { _, _ in updateHighlight() }
    }
    
    private func updateTooth(_ tooth: ToothObject) {
        mouth[tooth.toothNumber] = tooth
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
        withAnimation(.easeInOut(duration: 0.2)) {
            selectionModel.selectedCells = newSelection
        }
    }
    
}
