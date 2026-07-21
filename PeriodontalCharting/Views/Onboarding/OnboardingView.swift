import SwiftUI
import Foundation

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


#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
}
