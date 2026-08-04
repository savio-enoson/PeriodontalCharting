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
    @State private var enrollmentStatus = ""
    @State private var enrollmentDetail = ""
    @State private var enrollmentSucceeded = false
    @State private var isEnrolling = false
    
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
                    
                    Text("Please read the whole passage aloud at a normal pace. The length is what lets the app tell "
                         + "your voice apart from an assistant's.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // ~80 words. Two separate mechanisms depend on the length:
                    // the GATE builds its centroid from 3 s windows (several beat
                    // one — worth ~8x EER), and the EXTRACTOR needs 10.24 s of
                    // speech to fill its 1024 conditioning keys, below which it
                    // refuses to enroll at all.
                    //
                    // The digit run at the end is deliberate: it is the speech
                    // style the clinician actually dictates in, and it is the
                    // dominant ASR failure mode, so the enrollment should cover it
                    // rather than being all prose.
                    Text("""
                    "Dokter gigi menyarankan untuk menggosok gigi sebanyak dua kali \
                    sehari, terutama sebelum tidur malam, guna menjaga kesehatan gusi Anda.

                    Pemeriksaan periodontal dilakukan menyeluruh pada setiap permukaan \
                    gigi, mulai dari kuadran satu sampai kuadran empat."
                    """)
                        .font(.body)
                        .lineSpacing(4)
                        .padding()
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    HStack {
                        Button(action: {
                            if audioManager.isRecording {
                                audioManager.stopRecording()
                                hasRecorded = true
                                enrollCalibration()
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

                    if isEnrolling || !enrollmentStatus.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                if isEnrolling {
                                    ProgressView()
                                } else {
                                    Image(systemName: enrollmentSucceeded
                                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(enrollmentSucceeded ? .green : .orange)
                                }
                                Text(isEnrolling ? "Registering your voice…" : enrollmentStatus)
                                    .font(.footnote)
                            }
                            if !enrollmentDetail.isEmpty && !isEnrolling {
                                Text(enrollmentDetail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Enrollment

    /// Build the speaker centroid from the calibration recording.
    ///
    /// The work lives on TranscriptionEngine so onboarding and launch-time restore
    /// share ONE implementation; this is purely state assignment and message
    /// mapping. Reports every stage, because "no usable speech" on its own cannot
    /// distinguish a half-written file from a dead mic from spans that were merely
    /// too short.
    ///
    /// The EXTRACTOR is re-enrolled from the same recording afterwards, and it is
    /// a genuinely different mechanism: the gate wants a centroid over a few clean
    /// 3 s windows (WeSpeaker vs SpeechBrain ECAPA — different weights, different
    /// embedding space), the extractor wants 1024 frame-level keys, which needs
    /// >= 10.3 s of speech. A recording can succeed for one and fail for the
    /// other, so both results are reported.
    private func enrollCalibration() {
        isEnrolling = true
        enrollmentStatus = ""
        enrollmentDetail = ""

        Task {
            let result = await TranscriptionEngine.shared.enrollFromCalibration(
                reset: true, waitForFile: true)

            isEnrolling = false
            enrollmentSucceeded = result.templates > 0

            let base = String(format: "%.1f s audio · %d speech segment(s) · %d at least 3 s",
                              result.seconds, result.totalSpans, result.eligibleSpans)

            if result.templates > 0 {
                enrollmentStatus = "Voice registered — \(result.templates) template(s)."
                enrollmentDetail = base

                // Rebuild enroll_kv from the NEW recording. Skipping this leaves
                // the extractor conditioned on the previous clinician's voice —
                // which would still "work", on the wrong person.
                await TSEEngine.shared.reprepare()
                enrollmentDetail = base + "\n" + TSEEngine.shared.status
            } else if result.seconds < 1.0 {
                enrollmentStatus = "Recording is too short or unreadable."
                enrollmentDetail = String(format: "Read %.1f s after 3 s of retries. "
                                        + "Record for at least 5 seconds.", result.seconds)
            } else if result.totalSpans == 0 {
                enrollmentStatus = "No speech detected in the recording."
                enrollmentDetail = base + ". Check the microphone is not muted, and "
                                 + "play the recording back to confirm."
            } else {
                enrollmentStatus = "Speech found, but no template could be built."
                enrollmentDetail = base + ". The embedder rejected every segment — "
                                 + "check SpeakerEmbedding_ECAPA.mlpackage is in the target."
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
