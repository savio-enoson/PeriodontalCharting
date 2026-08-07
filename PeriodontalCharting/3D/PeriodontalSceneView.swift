//
//  PeriodontalSceneView.swift
//  PeriodontalCharting
//
//  The 3-D counterpart to the 2-D chart: the static dentition plus procedural
//  gum + alveolar bone, generated from whatever `[Int: ToothObject]` mouth the
//  caller hands it — the exact dictionary `ChartDashboard` edits and
//  `PatientChart.mouth` persists, so the model always matches the chart on
//  screen. Ported and trimmed from the 3DTeeth prototype's PerioSceneView
//  (drops the prototype's mock-data markers/heat-map modes, which have no
//  equivalent in this app's chart model).
//

import SwiftUI
import RealityKit
import UIKit
import simd

/// Holds the long-lived RealityKit entities so gestures and the update closure
/// can reach them across SwiftUI view updates.
@MainActor
final class PeriodontalSceneHolder {
    let root = Entity()
    let pivot = Entity()
    let camera = PerspectiveCamera()

    var loaded: LoadedTeeth?
    var anatomy: GingivalAnatomyGenerator.Anatomy?
    /// A translucent glowing shell parented to the selected tooth. Selection is
    /// shown by adding/removing this overlay — the tooth's own material is never
    /// modified, so a deselected tooth is always its original colour.
    var highlight: Entity?
    var selectedFDI: Int?

    var cameraBase: Float = 0.45

    // Cached "applied" state so we only rebuild visuals when something changed.
    var appliedMouth: [Int: ToothObject]?
    var appliedSelection: Int??
    var appliedGumOpacity: Float?
    var appliedArches: Set<DentalArch>?
}

/// Which arch(es) the 3-D view shows: the whole dentition, or one arch in
/// isolation so the occlusal surfaces and palatal/lingual sites aren't hidden
/// behind the opposing teeth.
enum ArchFilter: String, CaseIterable, Identifiable {
    case both, upper, lower
    var id: String { rawValue }

    var label: String {
        switch self {
        case .both:  return "Both"
        case .upper: return "Upper"
        case .lower: return "Lower"
        }
    }

    var arches: Set<DentalArch> {
        switch self {
        case .both:  return [.maxilla, .mandible]
        case .upper: return [.maxilla]
        case .lower: return [.mandible]
        }
    }
}

struct PeriodontalSceneView: View {
    /// The chart being visualised — same shape as `PatientChart.mouth`.
    var mouth: [Int: ToothObject]

    @State private var holder = PeriodontalSceneHolder()

    // Orbit / zoom state.
    @State private var yaw: Float = 0.5
    @State private var pitch: Float = -0.3
    @State private var zoom: Float = 1.0
    @GestureState private var dragDelta: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1.0

    @State private var status: LoadStatus = .loading
    @State private var selectedFDI: Int?
    /// Whole dentition, or a single arch shown in isolation.
    @State private var archFilter: ArchFilter = .both
    /// 0 = fully see-through, 1 = opaque. Purely a material property, so
    /// dragging this never regenerates the gum/bone mesh.
    @State private var gumOpacity: Double = Double(GingivalAnatomyGenerator.defaultGumOpacity)

    enum LoadStatus: Equatable { case loading, ready, failed(String) }

    var body: some View {
        ZStack {
            RealityView { content in
                buildStaticScene(into: content)
                await loadDentition()
            } update: { _ in
                applyOrbit()
                applyVisualization()
            }
            .gesture(orbitGesture)
            .simultaneousGesture(zoomGesture)
            .simultaneousGesture(selectGesture)

            overlay
        }
        .background(sceneBackground)
    }

    // MARK: - Scene construction

    private func buildStaticScene(into content: some RealityViewContentProtocol) {
        holder.root.addChild(holder.pivot)

        positionCamera()
        holder.root.addChild(holder.camera)

        // Three-point-ish directional lighting (no environment asset needed).
        addLight(direction: [-0.4, -0.7, -0.6], intensity: 9_000)
        addLight(direction: [0.6, -0.2, -0.5], intensity: 5_000)
        addLight(direction: [0.1, 0.6, 0.8], intensity: 3_500)

        content.add(holder.root)
    }

    private func addLight(direction: SIMD3<Float>, intensity: Float) {
        let light = DirectionalLight()
        light.light.intensity = intensity
        light.look(at: .zero, from: -normalize(direction), relativeTo: nil)
        holder.root.addChild(light)
    }

    private func loadDentition() async {
        do {
            let loaded = try await ToothMeshLoader.load()
            holder.loaded = loaded
            holder.pivot.addChild(loaded.modelRoot)
            holder.cameraBase = max(0.3, loaded.boundingRadius * 2.6)
            setupToothColliders(loaded)
            rebuildAnatomy(loaded)
            positionCamera()
            holder.appliedMouth = nil
            holder.appliedSelection = nil
            applyVisualization()
            status = .ready
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// (Re)generate the gum + bone layer from the current chart data.
    private func rebuildAnatomy(_ loaded: LoadedTeeth) {
        holder.anatomy.map { [$0.gum, $0.bone].forEach { $0.removeFromParent() } }
        let anatomy = GingivalAnatomyGenerator.build(from: loaded, mouth: mouth,
                                                     arches: archFilter.arches)
        loaded.modelRoot.addChild(anatomy.gum)
        loaded.modelRoot.addChild(anatomy.bone)
        holder.anatomy = anatomy
    }

    private func setupToothColliders(_ loaded: LoadedTeeth) {
        for (_, entity) in loaded.toothEntity {
            // Make teeth tappable via a cheap bounding-box collider.
            let bounds = entity.visualBounds(relativeTo: entity)
            entity.components.set(InputTargetComponent())
            entity.components.set(CollisionComponent(shapes: [
                .generateBox(size: bounds.extents).offsetBy(translation: bounds.center)
            ]))
        }
    }

    // MARK: - Data-driven visuals

    private func applyVisualization() {
        guard let loaded = holder.loaded else { return }

        // Skip entirely if nothing that affects the visuals changed.
        if holder.appliedMouth == mouth,
           holder.appliedSelection == .some(selectedFDI),
           holder.appliedGumOpacity == Float(gumOpacity),
           holder.appliedArches == archFilter.arches { return }

        // Geometry-affecting: the chart data changing, or the shown arch(es)
        // changing, warrants a rebuild. A missing-tooth flag flip also needs the
        // presence loop below to rerun, even though it touches no geometry itself.
        let mouthChanged = holder.appliedMouth != mouth
        let archesChanged = holder.appliedArches != archFilter.arches
        if mouthChanged || archesChanged {
            rebuildAnatomy(loaded)
            holder.appliedMouth = mouth
            holder.appliedArches = archFilter.arches
            holder.appliedGumOpacity = nil   // freshly-built gum needs the tint reapplied
        }
        holder.anatomy?.gum.isEnabled = true

        // Material-only: cheap enough to run every slider tick without touching geometry.
        if holder.appliedGumOpacity != Float(gumOpacity), let gum = holder.anatomy?.gum {
            GingivalAnatomyGenerator.setGumOpacity(Float(gumOpacity), on: gum)
            holder.appliedGumOpacity = Float(gumOpacity)
        }

        let selectionChanged = holder.appliedSelection != .some(selectedFDI)
        guard mouthChanged || archesChanged || selectionChanged else { return }
        holder.appliedSelection = .some(selectedFDI)

        // A tooth is shown only when its arch is visible and the chart doesn't
        // record it as missing.
        let visibleArches = archFilter.arches
        for (fdi, entity) in loaded.toothEntity {
            let inVisibleArch = visibleArches.contains(DentalArch.arch(ofFDI: fdi))
            entity.isEnabled = inVisibleArch && mouth[fdi]?.missing != true
        }
        updateSelectionHighlight(loaded)
    }

    /// Show the selected tooth by parenting a translucent glowing shell to it —
    /// added on select, removed on deselect. Exactly one shell ever exists, and
    /// the tooth's own material is untouched, so deselecting always leaves it in
    /// its normal colour.
    private func updateSelectionHighlight(_ loaded: LoadedTeeth) {
        holder.highlight?.removeFromParent()
        holder.highlight = nil

        guard let fdi = selectedFDI,
              let entity = loaded.toothEntity[fdi], entity.isEnabled,
              let mesh = entity.components[ModelComponent.self]?.mesh else { return }

        let accent = UIColor(red: 0.16, green: 0.38, blue: 0.86, alpha: 1)
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: accent)
        mat.emissiveColor = .init(color: accent)
        mat.emissiveIntensity = 0.9
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.30))
        mat.faceCulling = .none

        let shell = ModelEntity(mesh: mesh, materials: [mat])
        // Grow ~4% about the tooth's own centre so the glow reads as a rim around
        // the crown rather than z-fighting the surface. Uniform scale about the
        // centroid `c` is `s·p + (1−s)·c`, so offset the shell by `(1−s)·c`.
        let c = entity.visualBounds(relativeTo: entity).center
        let s: Float = 1.04
        shell.scale = SIMD3(repeating: s)
        shell.position = c * (1 - s)
        entity.addChild(shell)
        holder.highlight = shell
    }

    // MARK: - Camera / orbit

    private func positionCamera() {
        let distance = holder.cameraBase / max(0.4, zoom * Float(pinch))
        let dir = normalize(SIMD3<Float>(0, 0.35, 1))
        holder.camera.look(at: .zero, from: dir * distance, relativeTo: nil)
    }

    private func applyOrbit() {
        let liveYaw = yaw + Float(dragDelta.width) * 0.01
        let livePitch = max(-1.2, min(1.2, pitch + Float(dragDelta.height) * 0.01))
        holder.pivot.orientation =
            simd_quatf(angle: liveYaw, axis: [0, 1, 0]) *
            simd_quatf(angle: livePitch, axis: [1, 0, 0])
        positionCamera()
    }

    // MARK: - Gestures

    private var orbitGesture: some Gesture {
        DragGesture()
            .updating($dragDelta) { value, state, _ in state = value.translation }
            .onEnded { value in
                yaw += Float(value.translation.width) * 0.01
                pitch = max(-1.2, min(1.2, pitch + Float(value.translation.height) * 0.01))
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                zoom = max(0.4, min(4, zoom * Float(value.magnification)))
            }
    }

    private var selectGesture: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                var node: Entity? = value.entity
                while let n = node {
                    if let id = n.components[ToothID.self] {
                        let newSelection = selectedFDI == id.fdi ? nil : id.fdi
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFDI = newSelection
                        }
                        holder.selectedFDI = newSelection
                        return
                    }
                    node = n.parent
                }
            }
    }

    // MARK: - Overlay chrome

    @ViewBuilder private var overlay: some View {
        switch status {
        case .loading:
            ProgressView("Loading dentition…")
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title)
                Text("Couldn't load the model").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        case .ready:
            VStack {
                HStack(alignment: .top) {
                    Spacer()
                    archControl
                    Spacer()
                }
                .padding(.top, 10)
                Spacer()
                HStack(alignment: .bottom) {
                    Label(selectedFDI == nil
                            ? "Drag to orbit · pinch to zoom · tap a tooth"
                            : "Tap the tooth again to deselect",
                          systemImage: "hand.draw")
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                    Spacer()
                    gumOpacityControl
                }
                .padding(10)
            }
            .overlay(alignment: .topTrailing) { selectedToothPanel }
        }
    }

    /// The tapped tooth's chart status, drawn from the same cells as the 2-D chart.
    @ViewBuilder private var selectedToothPanel: some View {
        if let fdi = selectedFDI, let tooth = mouth[fdi] {
            ToothStatusPanel(tooth: tooth)
                .padding(.top, 60)   // clear the arch picker
                .padding(.trailing, 10)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// The app's brand navy (matches the chart's buttons and segmented tints).
    fileprivate static let controlAccent = Color(red: 0.05, green: 0.2, blue: 0.5)

    private var archControl: some View {
        Picker("Arch", selection: $archFilter) {
            ForEach(ArchFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .tint(Self.controlAccent)
    }

    private var gumOpacityControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.caption)
                .foregroundStyle(.primary)
            Slider(value: $gumOpacity, in: 0.1...1.0)
                .frame(width: 140)
                .tint(Self.controlAccent)
            Image(systemName: "eye.fill")
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var sceneBackground: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)],
                       startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
}

// MARK: - Presentation chrome

/// Full-screen wrapper: the 3-D view plus a "this patient / healthy control"
/// toggle and bone visibility switch, presented from `ChartDashboard`.
struct PeriodontalAnatomyPresenter: View {
    var mouth: [Int: ToothObject]
    @Environment(\.dismiss) private var dismiss
    @State private var showHealthyControl = false

    private var displayedMouth: [Int: ToothObject] {
        showHealthyControl ? mouth.healthyControl() : mouth
    }

    var body: some View {
        NavigationStack {
            PeriodontalSceneView(mouth: displayedMouth)
                .navigationTitle("3D Anatomy")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        Picker("Tissue", selection: $showHealthyControl) {
                            Text("This patient").tag(false)
                            Text("Healthy control").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .tint(PeriodontalSceneView.controlAccent)
                    }
                }
        }
    }
}

extension Dictionary where Key == Int, Value == ToothObject {
    /// An idealised, disease-free version of this mouth — same present teeth,
    /// but every site healthy (shallow sulcus, margin at the CEJ, no
    /// bleeding/mobility). Used as a side-by-side control in the 3-D view.
    func healthyControl() -> [Int: ToothObject] {
        mapValues { tooth in
            guard !tooth.missing else { return tooth }
            var t = tooth
            t.probingDepth = AspectData(outer: [2, 2, 2], inner: [2, 2, 2])
            t.gingivalMargin = AspectData(outer: [1, 1, 1], inner: [1, 1, 1])
            t.bleeding = AspectData(outer: [false, false, false], inner: [false, false, false])
            t.mobility = .zero
            return t
        }
    }
}
