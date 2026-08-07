import SwiftUI
import Foundation

struct OnboardingView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var hasCompletedOnboarding: Bool
    var isSettingsMode: Bool = false

    @StateObject private var audioManager = AudioManager.shared
    /// @Observable singleton — reading its properties in `body` registers this
    /// view for updates, so the take list and the spread warning stay live.
    private let profileStore = VoiceProfileStore.shared

    @State private var config = ChartingConfiguration()
    /// Which takes exist on disk FOR THE ACTIVE PROFILE. Per-take rather than one
    /// `hasRecorded` flag, because calibration is several recordings in different
    /// conditions — see CalibrationTake for why one was not enough.
    @State private var recordedTakes: Set<CalibrationTake> = []
    /// The take currently being recorded. There is ONE AVAudioRecorder, so only
    /// one row can be live at a time and every other Record button is disabled.
    @State private var recordingTake: CalibrationTake?
    /// Local edit buffer for the profile name, committed on submit / on save.
    @State private var profileName: String = ""
    @State private var recordingPermissionGranted = false
    @State private var enrollmentStatus = ""
    @State private var enrollmentDetail = ""
    @State private var enrollmentSucceeded = false
    @State private var isEnrolling = false

    /// There is no centroid at all without take 1.
    private var hasRecorded: Bool { recordedTakes.contains(.normal) }

    /// The gate arms on TEMPLATES, not on a file existing. A take that recorded
    /// fine but failed enrollment leaves `speakerVerdict` returning `.matched`
    /// for every voice in the room — the one thing this app exists to prevent —
    /// so completion waits for the templates, not for the WAV.
    private var isEnrolled: Bool { !(profileStore.active?.templates.isEmpty ?? true) }

    /// Enforced on FIRST RUN only. The button previously read
    /// `.disabled(!hasRecorded && false)`, which is unconditionally enabled.
    ///
    /// Not enforced in settings: the app is already armed there, and this same
    /// button commits the annotation order, so blocking it would trap an
    /// unrelated edit behind a re-calibration.
    private var canComplete: Bool { isSettingsMode || isEnrolled }

    private var activeProfileID: String? { profileStore.activeID }
    private var profileDirectory: URL? { profileStore.activeDirectory }

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

                // The store could not read its own index and has stopped writing
                // to avoid destroying it. Nothing else in the app would show
                // this, and the gate is OFF while it is true.
                if let loadError = profileStore.loadError {
                    Label(loadError, systemImage: "exclamationmark.octagon.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.red.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 12))
                }

                // --- Section 1: Voice Profile ---
                //
                // Each dentist gets their own profile: their own takes, their own
                // centroid, their own operating point. A clinic with a rotation
                // switches between them rather than re-calibrating, which used to
                // be the only option because templates lived in memory only.
                VStack(spacing: 16) {
                    Text("1. Voice Profile")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isSettingsMode {
                        HStack {
                            Text("Dentist")
                                .foregroundStyle(.secondary)
                            Spacer()
                            // Menu rather than segmented: names are variable-length
                            // and a rotation can be more than three or four people,
                            // which a segmented control cannot lay out.
                            Picker("Dentist", selection: Binding(
                                get: { profileStore.activeID ?? "" },
                                set: { switchProfile(to: $0) }
                            )) {
                                ForEach(profileStore.profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(audioManager.isRecording || isEnrolling)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                    }

                    HStack {
                        TextField("Dentist name", text: $profileName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitProfileName() }

                        if isSettingsMode {
                            Button {
                                addProfile()
                            } label: {
                                Label("Add", systemImage: "plus.circle.fill")
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 14)
                                    .background(Color(.systemGray5), in: Capsule())
                            }
                            .disabled(audioManager.isRecording || isEnrolling)
                        }
                    }

                    // Step 7's payload. Leave-one-out spread of this speaker's own
                    // calibration clips: the only threshold evidence calibration
                    // can produce, because a reject threshold needs somebody else
                    // to reject and there isn't one in here.
                    if let profile = profileStore.active,
                       let median = profile.selfDistanceMedian,
                       let worst = profile.selfDistanceMax {
                        HStack(spacing: 6) {
                            Image(systemName: profile.spreadIsRisky
                                  ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                .foregroundStyle(profile.spreadIsRisky ? .orange : .green)
                            Text(String(format: "Voice consistency: typical %.2f, worst %.2f "
                                        + "(the app stops recognising you past %.2f)",
                                        median, worst,
                                        profile.acceptThreshold ?? SpeakerGate.defaultAcceptThreshold))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    if let warning = profileStore.spreadWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()

                // --- Section 2: Voice Sample ---
                VStack(spacing: 20) {
                    Text("2. Voice Sample Calibration")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Read the passage below once for each condition. Recording more "
                         + "than one is what lets the app still recognise you when you "
                         + "change how you speak — measured, a single take made the app "
                         + "silence its own dentist whenever he lowered his voice.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // ~80 words. Two separate mechanisms depend on the length:
                    // the GATE builds its centroid from spans of this (several beat
                    // one — worth ~8x EER), and the EXTRACTOR needs 10.24 s of
                    // speech across all takes to fill its 1024 conditioning keys,
                    // below which it refuses to enroll at all.
                    //
                    // The digit run at the end is deliberate: it is the speech
                    // style the clinician actually dictates in, and it is the
                    // dominant ASR failure mode, so enrollment should cover it
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

                    ForEach(CalibrationTake.allCases) { take in
                        takeRow(take)
                    }

                    // The quiet take is the one that fixes the measured failure, so
                    // skipping it is called out rather than silently allowed.
                    if recordedTakes.contains(.normal) && !recordedTakes.contains(.soft) {
                        Label("Record the quiet take too. Without it the app will withhold "
                              + "your dictation whenever you speak softly.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

                // --- Section 3: Annotation Order Configuration ---
                VStack(spacing: 20) {
                    Text("3. Annotation Order")
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

                // V6. The gate is the control this app exists to provide, and it
                // was skippable by a literal `&& false`. Finishing setup without
                // enrolling leaves `speakerVerdict` returning `.matched` for
                // everything — every voice in the room reaches the chart.
                if !canComplete {
                    Label("Record the normal take and register your voice first. Until "
                          + "then the app cannot tell you from anyone else in the room, "
                          + "and every voice would reach the chart.",
                          systemImage: "exclamationmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: {
                    commitProfileName()
                    saveConfiguration()
                    hasCompletedOnboarding = true
                    dismiss()
                }) {
                    Text(isSettingsMode ? "Save" : "Complete Setup")
                        .font(.title3)
                        .fontWeight(.bold)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(canComplete
                                    ? Color(red: 0.05, green: 0.2, blue: 0.5)
                                    : Color(.systemGray3))
                        .foregroundStyle(.white)
                        .cornerRadius(16)
                }
                .disabled(!canComplete)
                .padding(.bottom, 40)

            }
            .padding(.horizontal, 40)
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .topTrailing) {
            if isSettingsMode {
                Button(action: { commitProfileName(); dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color(UIColor.tertiaryLabel))
                        .padding(24)
                }
            }
        }
        .onAppear {
            audioManager.prepareForCalibration()
            audioManager.requestPermission { granted in
                recordingPermissionGranted = granted
            }
            profileName = profileStore.active?.name ?? ""
            refreshRecordedTakes()
            config = ChartingConfiguration.loadSaved()
        }
        .onChange(of: profileStore.activeID) { _, _ in
            profileName = profileStore.active?.name ?? ""
            refreshRecordedTakes()
            enrollmentStatus = ""
            enrollmentDetail = ""
        }
        .onDisappear { commitProfileName() }
    }

    // MARK: - Profile

    private func refreshRecordedTakes() {
        guard let dir = profileDirectory else { recordedTakes = []; return }
        recordedTakes = Set(CalibrationTake.recorded(in: dir))
    }

    /// Save the edited name. Called on submit, on save, and on dismiss, because a
    /// TextField that is never submitted would otherwise lose what was typed.
    private func commitProfileName() {
        guard let id = activeProfileID else { return }
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profileStore.active?.name else { return }
        profileStore.rename(id, to: trimmed)
    }

    private func addProfile() {
        commitProfileName()
        let new = profileStore.createProfile(named: "Dentist \(profileStore.profiles.count + 1)")
        switchProfile(to: new.id)
    }

    /// Switching restores cached embeddings — no audio is read and no ECAPA pass
    /// runs — then re-conditions the extractor, which uses a different encoder and
    /// cannot be restored from the gate's embeddings.
    private func switchProfile(to id: String) {
        guard id != profileStore.activeID else { return }
        commitProfileName()
        Task { await TranscriptionEngine.shared.activateProfile(id) }
    }

    // MARK: - Calibration takes

    /// One take: what it is, why it exists, record and play.
    ///
    /// Files live inside the ACTIVE profile's directory. `AudioManager` appends
    /// whatever filename it is given to the Documents root, so a relative path
    /// with slashes routes correctly and AudioManager needs no change.
    ///
    /// Play is bound to THIS take via `audioManager.playingFilename` (which holds
    /// the last path component) rather than the global `isPlaying` flag. There is
    /// a single player, so a shared flag turned EVERY row's button into "Stop" the
    /// moment any one of them started.
    @ViewBuilder
    private func takeRow(_ take: CalibrationTake) -> some View {
        let isThisRecording = audioManager.isRecording && recordingTake == take
        let isThisPlaying = audioManager.playingFilename == take.filename
        let isDone = recordedTakes.contains(take)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(take.title).font(.headline)
                if isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if take.isRequired {
                    Text("required").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Text(take.instruction)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    guard let id = activeProfileID else { return }
                    if isThisRecording {
                        audioManager.stopRecording()
                        recordingTake = nil
                        recordedTakes.insert(take)
                        // Re-enroll from EVERY take of this profile, not just the
                        // one just recorded — the centroid is the average across
                        // all conditions, so adding one means rebuilding the whole.
                        enrollCalibration()
                    } else {
                        let path = profileStore.relativePath(take, for: id)
                        let begin = {
                            recordingTake = take
                            audioManager.startRecording(filename: path)
                        }
                        if recordingPermissionGranted {
                            begin()
                        } else {
                            audioManager.requestPermission { granted in
                                recordingPermissionGranted = granted
                                if granted { begin() }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: isThisRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title3)
                        Text(isThisRecording ? "Stop" : (isDone ? "Re-record" : "Record"))
                            .fontWeight(.bold)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: 200)
                    .background(isThisRecording ? Color.red : Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                }
                // One recorder, one file at a time.
                .disabled(audioManager.isRecording && !isThisRecording)

                if isDone {
                    Button {
                        guard let id = activeProfileID else { return }
                        if isThisPlaying {
                            audioManager.stopPlaying()
                        } else {
                            // One player — stop whatever else is going first.
                            if audioManager.isPlaying { audioManager.stopPlaying() }
                            audioManager.playRecording(
                                filename: profileStore.relativePath(take, for: id))
                        }
                    } label: {
                        HStack {
                            Image(systemName: isThisPlaying ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title3)
                            Text(isThisPlaying ? "Stop" : "Play")
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: 110)
                        .background(Color(.systemGray5))
                        .foregroundStyle(.primary)
                        .cornerRadius(12)
                    }
                    .disabled(audioManager.isRecording)
                }

                Spacer()
            }
        }
        .padding(12)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Enrollment

    /// Build the speaker centroid from EVERY calibration take of the ACTIVE profile.
    ///
    /// The work lives on TranscriptionEngine so onboarding and launch-time restore
    /// share ONE implementation; this is state assignment and message mapping.
    /// Reports every stage, because "no usable speech" on its own cannot
    /// distinguish a half-written file from a dead mic from spans that were merely
    /// too thin on voice.
    ///
    /// `reset: true` ALWAYS. Every take is re-read from disk on each call, so
    /// stacking without a reset would double-count the takes that have not
    /// changed — and `SpeakerGate` evicts FIFO past 16 templates, so the oldest
    /// condition would then be the one silently dropped.
    ///
    /// The EXTRACTOR is re-enrolled from the same recordings afterwards, and it is
    /// a genuinely different mechanism: the gate wants a centroid over a few clean
    /// spans spanning several conditions (SpeechBrain ECAPA), the extractor wants
    /// 1024 frame-level keys and needs >= 10.3 s of speech in total (WeSpeaker
    /// ECAPA — different weights, unrelated embedding space).
    private func enrollCalibration() {
        isEnrolling = true
        enrollmentStatus = ""
        enrollmentDetail = ""

        Task {
            let result = await TranscriptionEngine.shared.enrollFromCalibration(
                reset: true, waitForFile: true)

            isEnrolling = false
            enrollmentSucceeded = result.templates > 0
            refreshRecordedTakes()

            let base = String(format: "%d take(s) · %.1f s audio · %d speech segment(s) · %d usable",
                              result.takes, result.seconds, result.totalSpans, result.eligibleSpans)

            if result.templates > 0 {
                enrollmentStatus = result.takes >= 2
                    ? "Voice registered — \(result.templates) template(s) across \(result.takes) conditions."
                    : "Voice registered — \(result.templates) template(s) from one condition."
                enrollmentDetail = base

                // Rebuild enroll_kv from the NEW recordings. Skipping this leaves
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
        config.saveAsDefault()
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
