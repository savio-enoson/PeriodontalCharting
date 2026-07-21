import SwiftUI

struct ChartDashboard: View {
    @State private var mouth: [Int: ToothObject] = ToothObject.fullMouthMock()
    @State private var isSingleColumn = false
    @State private var currentScale: CGFloat = 1.0
    @State private var finalScale: CGFloat = 1.0
    @State private var baseSize: CGSize = .zero
    @StateObject private var selectionModel = ChartSelectionModel()
    @StateObject private var aiViewModel = AIVoiceViewModel()
    @State private var showDebugMenu = false
    @State private var showAIMode = false
    @State private var showSettings = false
    @Binding var columnVisibility: NavigationSplitViewVisibility

    private var q1: [ToothObject] { [18,17,16,15,14,13,12,11].compactMap { mouth[$0] } }
    private var q2: [ToothObject] { [21,22,23,24,25,26,27,28].compactMap { mouth[$0] } }
    private var q4: [ToothObject] { [48,47,46,45,44,43,42,41].compactMap { mouth[$0] } }
    private var q3: [ToothObject] { [31,32,33,34,35,36,37,38].compactMap { mouth[$0] } }

    var body: some View {
        let scale = finalScale * currentScale * (isSingleColumn ? 1.35 : 1.0)

        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 40) {
                if isSingleColumn {
                    QuadrantView(title: "Quadrant 1 (Upper Right)", teeth: q1, isUpperJaw: true,  showLeftLabels: true,  showRightLabels: false)
                    QuadrantView(title: "Quadrant 2 (Upper Left)",  teeth: q2, isUpperJaw: true,  showLeftLabels: true,  showRightLabels: false)
                    QuadrantView(title: "Quadrant 4 (Lower Right)", teeth: q4, isUpperJaw: false, showLeftLabels: true,  showRightLabels: false)
                    QuadrantView(title: "Quadrant 3 (Lower Left)",  teeth: q3, isUpperJaw: false, showLeftLabels: true,  showRightLabels: false)
                } else {
                    // Upper Jaw
                    HStack(alignment: .top, spacing: 24) {
                        QuadrantView(title: "Quadrant 1 (Upper Right)", teeth: q1, isUpperJaw: true, showLeftLabels: true,  showRightLabels: false)
                        QuadrantView(title: "Quadrant 2 (Upper Left)",  teeth: q2, isUpperJaw: true, showLeftLabels: false, showRightLabels: true)
                    }
                    // Lower Jaw
                    HStack(alignment: .top, spacing: 24) {
                        QuadrantView(title: "Quadrant 4 (Lower Right)", teeth: q4, isUpperJaw: false, showLeftLabels: true,  showRightLabels: false)
                        QuadrantView(title: "Quadrant 3 (Lower Left)",  teeth: q3, isUpperJaw: false, showLeftLabels: false, showRightLabels: true)
                    }
                }
            }
            .padding(24)
            .padding(.top, 70) // Push content down to avoid overlapping with floating toolbar
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { baseSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in baseSize = newSize }
                }
            )
            .scaleEffect(scale)
            .frame(
                width:  baseSize == .zero ? nil : baseSize.width  * scale,
                height: baseSize == .zero ? nil : baseSize.height * scale
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let proposedScale = finalScale * value
                        if proposedScale < 1.0 {
                            currentScale = 1.0 / finalScale
                        } else {
                            currentScale = value
                        }
                    }
                    .onEnded { _ in
                        finalScale *= currentScale
                        if finalScale < 1.0 {
                            finalScale = 1.0
                        }
                        currentScale = 1.0
                    }
            )
        }
        .background(.background)
        .overlay(alignment: .topTrailing) {
            let darkBlue = Color(red: 0.05, green: 0.2, blue: 0.5)
            HStack(spacing: 20) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showAIMode.toggle() }
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
                    withAnimation {
                        finalScale   = 1.0
                        currentScale = 1.0
                    }
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
        .environmentObject(selectionModel)
        .sheet(isPresented: $showDebugMenu) {
            SelectionDebugMenu()
                .environmentObject(selectionModel)
        }
        .sheet(isPresented: $showSettings) {
            OnboardingView(hasCompletedOnboarding: .constant(true), isSettingsMode: true)
        }
    }
}
