//
//  ToothMeshLoader.swift
//  PeriodontalCharting
//
//  Loads the static dentition (baked_teeth.usdc) and, because the mesh names in
//  this asset are unreliable, derives each tooth's FDI identity from its position
//  around the arch. Ported from the 3DTeeth prototype's TeethModel.swift —
//  purely geometric, with no dependency on the chart data model.
//

import Foundation
import RealityKit
import simd

/// Tags a RealityKit entity (a tooth mesh or its marker) with the FDI number it
/// represents, so a tap can be resolved back to a chart record.
struct ToothID: Component {
    let fdi: Int
}

/// The result of loading and identifying the dentition.
@MainActor
struct LoadedTeeth {
    /// Frame in which tooth centroids are expressed and markers are added.
    /// The caller parents this under a pivot for orbiting.
    let modelRoot: Entity
    /// FDI -> the tooth's mesh entity.
    let toothEntity: [Int: Entity]
    /// FDI -> centroid in `modelRoot` space.
    let centroid: [Int: SIMD3<Float>]
    /// FDI -> that tooth's mesh vertices in `modelRoot` space (for surface hugging).
    let vertices: [Int: [SIMD3<Float>]]
    /// FDI -> the tooth's true CEJ height (Y in `modelRoot` space), taken from the
    /// asset's baked `CEJ_*` markers. The keystone landmark for every measurement.
    let cejY: [Int: Float]
    /// Arch -> horizontal centre of that arch's centroids (for outward offsets).
    let archCentre: [DentalArch: SIMD3<Float>]
    /// Half the model's largest dimension — a good camera framing distance base.
    let boundingRadius: Float
}

@MainActor
enum ToothMeshLoader {

    /// Target size of the model's largest dimension, in metres.
    private static let targetSize: Float = 0.16

    /// Correction applied to the imported asset to stand it upright.
    /// `baked_teeth.usdc` is authored Z-up; RealityKit is Y-up. Tuned against the
    /// simulator — kept as one constant so it is trivial to re-tune.
    private static let uprightRotation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])

    static func load() async throws -> LoadedTeeth {
        guard let url = Bundle.main.url(forResource: "baked_teeth", withExtension: "usdc") else {
            throw LoadError.assetMissing
        }
        let asset = try await Entity(contentsOf: url)

        // --- Normalise: upright, uniformly scaled, centred at the origin. ------
        let modelRoot = Entity()
        modelRoot.name = "modelRoot"
        modelRoot.addChild(asset)
        asset.orientation = uprightRotation

        let pre = asset.visualBounds(relativeTo: modelRoot)
        let maxDim = max(pre.extents.x, max(pre.extents.y, pre.extents.z))
        let scale = maxDim > 0 ? targetSize / maxDim : 1
        asset.scale = SIMD3(repeating: scale)

        let post = asset.visualBounds(relativeTo: modelRoot)
        asset.position -= post.center

        // --- Collect the tooth meshes. ----------------------------------------
        var meshes: [Entity] = []
        collectModelEntities(asset, into: &meshes)

        // --- Split into arches, then identify each tooth by arch position. ----
        let (maxilla, mandible) = splitArches(meshes, in: modelRoot)

        var toothEntity: [Int: Entity] = [:]
        var centroid: [Int: SIMD3<Float>] = [:]
        var archCentre: [DentalArch: SIMD3<Float>] = [:]

        for (arch, group) in [(DentalArch.maxilla, maxilla), (DentalArch.mandible, mandible)] {
            let ordered = orderAroundArch(group, in: modelRoot)
            let fdis = arch.fdiOrder
            var sum = SIMD3<Float>.zero
            for (i, entity) in ordered.prefix(fdis.count).enumerated() {
                let fdi = fdis[i]
                let c = entity.visualBounds(relativeTo: modelRoot).center
                entity.components.set(ToothID(fdi: fdi))
                toothEntity[fdi] = entity
                centroid[fdi] = c
                sum += c
            }
            if !ordered.isEmpty {
                archCentre[arch] = sum / Float(min(ordered.count, fdis.count))
            }
        }

        var vertices: [Int: [SIMD3<Float>]] = [:]
        for (fdi, entity) in toothEntity {
            vertices[fdi] = extractVertices(entity, relativeTo: modelRoot)
        }

        // The asset ships `CEJ_*` marker Xforms; match each to its nearest tooth
        // to get the true cementoenamel-junction height in model space.
        var cejMarkers: [SIMD3<Float>] = []
        collectCEJMarkers(asset, relativeTo: modelRoot, into: &cejMarkers)
        var cejY: [Int: Float] = [:]
        for (fdi, c) in centroid {
            var best: (y: Float, d: Float)?
            for m in cejMarkers {
                let d = (m.x - c.x) * (m.x - c.x) + (m.z - c.z) * (m.z - c.z)
                if best == nil || d < best!.d { best = (m.y, d) }
            }
            if let best { cejY[fdi] = best.y }
        }

        let radius = asset.visualBounds(relativeTo: modelRoot).boundingRadius
        return LoadedTeeth(modelRoot: modelRoot,
                           toothEntity: toothEntity,
                           centroid: centroid,
                           vertices: vertices,
                           cejY: cejY,
                           archCentre: archCentre,
                           boundingRadius: radius)
    }

    enum LoadError: Error { case assetMissing }

    // MARK: - Geometry helpers

    /// Pull a mesh's vertex positions into `root` space, for surface measurement.
    private static func extractVertices(_ entity: Entity, relativeTo root: Entity) -> [SIMD3<Float>] {
        guard let mesh = entity.components[ModelComponent.self]?.mesh else { return [] }
        let m = entity.transformMatrix(relativeTo: root)
        var out: [SIMD3<Float>] = []
        for model in mesh.contents.models {
            for part in model.parts {
                for p in part.positions.elements {
                    let w = m * SIMD4<Float>(p, 1)
                    out.append(SIMD3(w.x, w.y, w.z))
                }
            }
        }
        return out
    }

    /// Gather the positions of the asset's `CEJ_*` marker Xforms in `root` space.
    private static func collectCEJMarkers(_ entity: Entity, relativeTo root: Entity,
                                          into out: inout [SIMD3<Float>]) {
        if entity.name.hasPrefix("CEJ_") {
            out.append(entity.position(relativeTo: root))
        }
        for child in entity.children { collectCEJMarkers(child, relativeTo: root, into: &out) }
    }

    private static func collectModelEntities(_ entity: Entity, into out: inout [Entity]) {
        if entity.components[ModelComponent.self] != nil {
            out.append(entity)
        }
        for child in entity.children { collectModelEntities(child, into: &out) }
    }

    /// Mandibular teeth live under a `Mandible_group…` node in this asset; fall
    /// back to a vertical (median-Y) split if that structure is ever missing.
    private static func splitArches(_ meshes: [Entity], in root: Entity) -> (maxilla: [Entity], mandible: [Entity]) {
        var maxilla: [Entity] = []
        var mandible: [Entity] = []
        for m in meshes {
            if ancestorNameContains(m, "Mandible") { mandible.append(m) } else { maxilla.append(m) }
        }
        if maxilla.count == 16 && mandible.count == 16 {
            return (maxilla, mandible)
        }
        // Fallback: split by height. The upper cluster (greater Y) is the maxilla.
        let sorted = meshes.sorted {
            $0.visualBounds(relativeTo: root).center.y > $1.visualBounds(relativeTo: root).center.y
        }
        let half = sorted.count / 2
        return (Array(sorted.prefix(half)), Array(sorted.suffix(from: half)))
    }

    private static func ancestorNameContains(_ entity: Entity, _ needle: String) -> Bool {
        var node: Entity? = entity
        while let n = node {
            if n.name.contains(needle) { return true }
            node = n.parent
        }
        return false
    }

    /// Walk the horseshoe: sort teeth by angle about the arch centre, then break
    /// the ring at its widest angular gap (the open posterior end between the two
    /// rearmost molars). Orientation is normalised so the sequence always begins
    /// on the −X side, giving a stable FDI assignment across both arches.
    private static func orderAroundArch(_ meshes: [Entity], in root: Entity) -> [Entity] {
        guard meshes.count > 2 else { return meshes }

        let centres = meshes.map { $0.visualBounds(relativeTo: root).center }
        let cx = centres.map(\.x).reduce(0, +) / Float(centres.count)
        let cz = centres.map(\.z).reduce(0, +) / Float(centres.count)

        var indexed = meshes.enumerated().map { (i, e) -> (entity: Entity, angle: Float) in
            let c = centres[i]
            return (e, atan2(c.z - cz, c.x - cx))
        }
        indexed.sort { $0.angle < $1.angle }

        // Largest wrap-around gap marks the arch opening.
        var gapAfter = indexed.count - 1
        var widest: Float = -1
        for i in 0..<indexed.count {
            let next = (i + 1) % indexed.count
            var gap = indexed[next].angle - indexed[i].angle
            if gap < 0 { gap += 2 * .pi }
            if gap > widest { widest = gap; gapAfter = i }
        }

        var ordered = Array(indexed[(gapAfter + 1)...] + indexed[...gapAfter]).map(\.entity)

        // Normalise handedness: always start on the −X side.
        if let first = ordered.first?.visualBounds(relativeTo: root).center,
           first.x > cx {
            ordered.reverse()
        }
        return ordered
    }
}
