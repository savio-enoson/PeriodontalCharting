import SwiftUI
import Foundation

struct TwoItemReorderable<Item: Hashable, Content: View>: View {
    @Binding var items: [Item]
    let spacing: CGFloat
    @ViewBuilder let content: (Item, AnyGesture<DragGesture.Value>) -> Content
    
    @State private var itemHeight: CGFloat = 80
    @State private var draggingItem: Item?
    @State private var dragOffset: CGFloat = 0
    @State private var isSwapped: Bool = false
    
    var body: some View {
        VStack(spacing: spacing) {
            ForEach(items, id: \.self) { item in
                let index = items.firstIndex(of: item) ?? 0
                let isDragging = draggingItem == item
                
                let nonDraggingOffset: CGFloat = {
                    if !isDragging && isSwapped {
                        return index == 1 ? -(itemHeight + spacing) : (itemHeight + spacing)
                    }
                    return 0
                }()
                
                let gesture = DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if draggingItem == nil {
                            draggingItem = item
                        }
                        dragOffset = value.translation.height
                        
                        let threshold = itemHeight / 3
                        let currentlySwapped = (index == 0 && dragOffset > threshold) ||
                                               (index == 1 && dragOffset < -threshold)
                        
                        if isSwapped != currentlySwapped {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isSwapped = currentlySwapped
                            }
                        }
                    }
                    .onEnded { value in
                        let finalizeSwap = isSwapped
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if finalizeSwap, items.count == 2 {
                                items.swapAt(0, 1)
                            }
                            draggingItem = nil
                            dragOffset = 0
                            isSwapped = false
                        }
                    }
                
                content(item, AnyGesture(gesture))
                    .offset(y: isDragging ? dragOffset : nonDraggingOffset)
                    .zIndex(isDragging ? 1 : 0)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    if geo.size.height > 10 { itemHeight = geo.size.height }
                                }
                                .onChange(of: geo.size.height) { newH in
                                    if newH > 10 { itemHeight = newH }
                                }
                        }
                    )
            }
        }
    }
}

struct OnboardingView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var hasCompletedOnboarding: Bool
    var isSettingsMode: Bool = false
    
    @StateObject private var audioManager = AudioManager.shared
    
    @State private var config = ChartingConfiguration()
    @State private var hasRecorded = false
    @State private var recordingPermissionGranted = false
    
    init(hasCompletedOnboarding: Binding<Bool>, isSettingsMode: Bool = false) {
        self._hasCompletedOnboarding = hasCompletedOnboarding
        self.isSettingsMode = isSettingsMode
        
        let appearance = UISegmentedControl.appearance()
        let darkBlue = UIColor(red: 0.05, green: 0.2, blue: 0.5, alpha: 1.0)
        appearance.selectedSegmentTintColor = darkBlue
        appearance.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Text(isSettingsMode ? "Settings" : "Welcome to Periodontal Charting")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.top, 40)
                
                // --- Section 1: Voice Sample ---
                VStack(spacing: 20) {
                    Text("1. Voice Sample Calibration")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text("Please record a voice sample speaking this text:")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text("\"Dokter gigi menyarankan untuk menggosok gigi sebanyak dua kali sehari, terutama sebelum tidur malam, guna menjaga kesehatan gusi Anda.\"")
                        .font(.title3)
                        .padding()
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    HStack {
                        Button(action: {
                            if audioManager.isRecording {
                                audioManager.stopRecording()
                                hasRecorded = true
                            } else {
                                if !recordingPermissionGranted {
                                    audioManager.requestPermission { granted in
                                        recordingPermissionGranted = granted
                                        if granted {
                                            audioManager.startRecording()
                                        }
                                    }
                                } else {
                                    audioManager.startRecording()
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: audioManager.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                    .font(.title2)
                                Text(audioManager.isRecording ? "Stop Recording" : "Record Voice Sample")
                                    .fontWeight(.bold)
                            }
                            .padding()
                            .frame(maxWidth: 300)
                            .background(audioManager.isRecording ? Color.red : Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                        }
                        
                        if audioManager.hasRecording {
                            Button(action: {
                                if audioManager.isPlaying {
                                    audioManager.stopPlaying()
                                } else {
                                    audioManager.playRecording()
                                }
                            }) {
                                HStack {
                                    Image(systemName: audioManager.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.title2)
                                    Text(audioManager.isPlaying ? "Stop" : "Play")
                                        .fontWeight(.bold)
                                }
                                .padding()
                                .frame(maxWidth: 120)
                                .background(Color(.systemGray5))
                                .foregroundStyle(.primary)
                                .cornerRadius(12)
                            }
                            
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Recorded")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                        Spacer()
                    }
                }
                .padding()
                
                // --- Section 2: Annotation Order Configuration ---
                VStack(spacing: 20) {
                    Text("2. Annotation Order")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    AnnotationVisualizerView(config: config)
                    
                    Picker("Primary Order", selection: $config.primaryOrder) {
                        ForEach(PrimaryOrderType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 16)
                    
                    // Display the configuration hierarchy
                    if config.primaryOrder == .jawFirst {
                        jawFirstHierarchyView
                    } else {
                        aspectFirstHierarchyView
                    }
                }
                .padding()
                
                Button(action: {
                    saveConfiguration()
                    hasCompletedOnboarding = true
                    dismiss()
                }) {
                    Text(isSettingsMode ? "Save" : "Complete Setup")
                        .font(.title3)
                        .fontWeight(.bold)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(red: 0.05, green: 0.2, blue: 0.5))
                        .foregroundStyle(.white)
                        .cornerRadius(16)
                }
                .disabled(!hasRecorded && false) // Usually we'd enforce it, maybe optional for debug
                .padding(.bottom, 40)
                
            }
            .padding(.horizontal, 40)
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .topTrailing) {
            if isSettingsMode {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color(UIColor.tertiaryLabel))
                        .padding(24)
                }
            }
        }
        .onAppear {
            audioManager.requestPermission { granted in
                recordingPermissionGranted = granted
            }
            if let data = UserDefaults.standard.data(forKey: "ChartingConfiguration"),
               let savedConfig = try? JSONDecoder().decode(ChartingConfiguration.self, from: data) {
                config = savedConfig
            }
        }
    }
    
    private func saveConfiguration() {
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: "ChartingConfiguration")
        }
    }
    
    private var dragHandle: some View {
        VStack(spacing: 3) {
            Circle().frame(width: 4, height: 4)
            Circle().frame(width: 4, height: 4)
            Circle().frame(width: 4, height: 4)
        }
        .foregroundColor(Color(UIColor.tertiaryLabel))
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle()) // makes the entire area draggable
    }
    
    private var largeDragHandle: some View {
        VStack(spacing: 4) {
            Circle().frame(width: 6, height: 6)
            Circle().frame(width: 6, height: 6)
            Circle().frame(width: 6, height: 6)
        }
        .foregroundColor(Color(UIColor.tertiaryLabel))
        .padding(.trailing, 16)
        .padding(.vertical, 24)
        .contentShape(Rectangle())
    }
    
    // MARK: - Jaw First Hierarchy
    private var jawFirstHierarchyView: some View {
        TwoItemReorderable(items: $config.jawOrder, spacing: 24) { jaw, parentGesture in
            HStack(spacing: 0) {
                largeDragHandle
                    .gesture(parentGesture)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text(jaw.rawValue)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    
                    let aspectBinding = jaw == .upper ? $config.upperAspectOrder : $config.lowerAspectOrder
                    
                    TwoItemReorderable(items: aspectBinding, spacing: 12) { aspect, childGesture in
                        HStack(spacing: 0) {
                            dragHandle
                                .gesture(childGesture)
                            Text(aspect.displayName(for: jaw)).frame(width: 100, alignment: .leading)
                            Spacer()
                            Picker("Dir", selection: directionBinding(jaw: jaw, aspect: aspect)) {
                                ForEach(AnnotationDirection.allCases, id: \.self) { dir in
                                    Text(dir.rawValue).tag(dir)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 260)
                        }
                        .padding(8)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(.systemGray5), lineWidth: 1)
            )
        }
    }
    
    // MARK: - Aspect First Hierarchy
    private var aspectFirstHierarchyView: some View {
        TwoItemReorderable(items: $config.aspectOrder, spacing: 24) { aspect, parentGesture in
            HStack(spacing: 0) {
                largeDragHandle
                    .gesture(parentGesture)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text(aspect.displayName(for: nil))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    
                    let jawBinding = aspect == .buccal ? $config.buccalJawOrder : $config.palatalJawOrder
                    
                    TwoItemReorderable(items: jawBinding, spacing: 12) { jaw, childGesture in
                        HStack(spacing: 0) {
                            dragHandle
                                .gesture(childGesture)
                            Text(jaw.rawValue).frame(width: 100, alignment: .leading)
                            Spacer()
                            Picker("Dir", selection: directionBinding(jaw: jaw, aspect: aspect)) {
                                ForEach(AnnotationDirection.allCases, id: \.self) { dir in
                                    Text(dir.rawValue).tag(dir)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 260)
                        }
                        .padding(8)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(.systemGray5), lineWidth: 1)
            )
        }
    }
    
    private func directionBinding(jaw: JawType, aspect: AspectType) -> Binding<AnnotationDirection> {
        Binding(
            get: { config.direction(for: jaw, aspect: aspect) },
            set: { config.setDirection($0, for: jaw, aspect: aspect) }
        )
    }
}

struct AnnotationVisualizerView: View {
    let config: ChartingConfiguration
    
    var body: some View {
        VStack(spacing: 24) {
            JawVisualizer(jaw: .upper, config: config)
            JawVisualizer(jaw: .lower, config: config)
        }
        .padding()
    }
}

struct JawVisualizer: View {
    let jaw: JawType
    let config: ChartingConfiguration
    
    var body: some View {
        VStack(spacing: 8) {
            Text("\(jaw.rawValue.capitalized) Jaw")
                .font(.subheadline)
                .fontWeight(.bold)
            
            // Inner Side (Top)
            visualizerOverlay(for: .palatal)
            
            // Teeth Placeholder
            HStack(spacing: 4) {
                ForEach(0..<16, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray4))
                        .frame(height: 32)
                }
            }
            .frame(height: 48)
            
            // Outer Side (Bottom)
            visualizerOverlay(for: .buccal)
        }
    }
    
    @ViewBuilder
    private func visualizerOverlay(for aspect: AspectType) -> some View {
        let index = config.sequenceIndex(for: jaw, aspect: aspect)
        let direction = config.direction(for: jaw, aspect: aspect)
        let sideText = aspect == .buccal ? "Outer Side" : "Inner Side"
        let isLeftToRight = direction == .leftToRight
        
        VStack(alignment: isLeftToRight ? .leading : .trailing, spacing: 4) {
            Text("\(index). \(sideText)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            HStack(spacing: 0) {
                if isLeftToRight {
                    Image(systemName: "\(index).circle.fill")
                        .foregroundColor(.blue)
                    Rectangle().fill(Color.blue).frame(height: 2)
                    Image(systemName: "arrowtriangle.forward.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 10))
                } else {
                    Image(systemName: "arrowtriangle.backward.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 10))
                    Rectangle().fill(Color.blue).frame(height: 2)
                    Image(systemName: "\(index).circle.fill")
                        .foregroundColor(.blue)
                }
            }
        }
    }
}

extension ChartingConfiguration {
    func sequenceIndex(for jaw: JawType, aspect: AspectType) -> Int {
        var result: [(JawType, AspectType)] = []
        if primaryOrder == .jawFirst {
            for j in jawOrder {
                let aspects = j == .upper ? upperAspectOrder : lowerAspectOrder
                for a in aspects {
                    result.append((j, a))
                }
            }
        } else {
            for a in aspectOrder {
                let jaws = a == .buccal ? buccalJawOrder : palatalJawOrder
                for j in jaws {
                    result.append((j, a))
                }
            }
        }
        
        return (result.firstIndex(where: { $0.0 == jaw && $0.1 == aspect }) ?? 0) + 1
    }
}

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
}
