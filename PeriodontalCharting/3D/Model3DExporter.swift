//
//  Model3DExporter.swift
//  PeriodontalCharting
//
//  Exports the same 3-D anatomy the `PeriodontalSceneView` shows — the present
//  teeth plus procedural gum + bone generated from the chart — as a Wavefront
//  OBJ or binary STL mesh. Built headlessly from the `[Int: ToothObject]` mouth,
//  so it never needs a live RealityView: it reloads the dentition via
//  `ToothMeshLoader` and regenerates the gum/bone via `GingivalAnatomyGenerator`,
//  exactly as the on-screen scene does, then walks the RealityKit meshes and
//  writes their triangles out.
//

import Foundation
import RealityKit
import simd

enum Model3DFormat: String {
    case obj, stl

    var label: String {
        switch self {
        case .obj: return "OBJ"
        case .stl: return "STL"
        }
    }
}

@MainActor
enum Model3DExporter {

    /// Rebuild the anatomy from `mouth` and write it to a temporary file.
    /// Returns the file URL, or `nil` if the dentition asset failed to load.
    static func export(mouth: [Int: ToothObject], format: Model3DFormat) async -> URL? {
        guard let loaded = try? await ToothMeshLoader.load() else { return nil }

        // Regenerate the gum/bone and parent them under the same modelRoot the
        // teeth live in, so every mesh transforms into one common space.
        let anatomy = GingivalAnatomyGenerator.build(from: loaded, mouth: mouth,
                                                     arches: Set(DentalArch.allCases))
        loaded.modelRoot.addChild(anatomy.gum)
        loaded.modelRoot.addChild(anatomy.bone)

        var mesh = TriangleMesh()

        // Present teeth only — a missing tooth is absent from the 3-D scene too.
        var exportedFDIs: [Int] = []
        for (fdi, entity) in loaded.toothEntity where mouth[fdi]?.missing != true {
            let before = mesh.positions.count
            append(entity, root: loaded.modelRoot, into: &mesh)
            if mesh.positions.count > before { exportedFDIs.append(fdi) }
        }
        let gumBefore = mesh.positions.count
        append(anatomy.gum, root: loaded.modelRoot, into: &mesh)
        let boneBefore = mesh.positions.count
        append(anatomy.bone, root: loaded.modelRoot, into: &mesh)

        #if DEBUG
        let mand = exportedFDIs.filter { DentalArch.arch(ofFDI: $0) == .mandible }.sorted()
        let max = exportedFDIs.filter { DentalArch.arch(ofFDI: $0) == .maxilla }.sorted()
        print("[Model3DExporter] loaded teeth: \(loaded.toothEntity.keys.sorted())")
        print("[Model3DExporter] exported maxilla \(max.count): \(max)")
        print("[Model3DExporter] exported mandible \(mand.count): \(mand)")
        print("[Model3DExporter] gum verts: \(boneBefore - gumBefore), bone verts: \(mesh.positions.count - boneBefore)")
        print("[Model3DExporter] total verts: \(mesh.positions.count), tris: \(mesh.indices.count / 3)")
        #endif

        guard !mesh.indices.isEmpty else { return nil }

        let data = format == .obj ? mesh.objData() : mesh.stlData()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeriodontalModel.\(format.rawValue)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Append an entity's mesh (transformed into `root` space) to the accumulator.
    private static func append(_ entity: Entity, root: Entity, into mesh: inout TriangleMesh) {
        guard let resource = entity.components[ModelComponent.self]?.mesh else { return }
        let transform = entity.transformMatrix(relativeTo: root)

        for model in resource.contents.models {
            for part in model.parts {
                let base = UInt32(mesh.positions.count)
                for p in part.positions.elements {
                    let w = transform * SIMD4<Float>(p, 1)
                    mesh.positions.append(SIMD3(w.x, w.y, w.z))
                }
                if let tris = part.triangleIndices?.elements {
                    for i in tris { mesh.indices.append(base + i) }
                } else {
                    // Non-indexed part: positions are already in triangle order.
                    for i in 0..<UInt32(part.positions.count) { mesh.indices.append(base + i) }
                }
            }
        }
    }
}

/// A flat vertex/triangle soup, plus the two text/binary serialisers.
private struct TriangleMesh {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    /// Wavefront OBJ (ASCII, 1-indexed faces).
    func objData() -> Data {
        var s = "# Periodontal charting 3-D export\n"
        s.reserveCapacity(positions.count * 28 + indices.count * 10)
        for p in positions {
            s += "v \(p.x) \(p.y) \(p.z)\n"
        }
        var i = 0
        while i + 2 < indices.count {
            s += "f \(indices[i] + 1) \(indices[i + 1] + 1) \(indices[i + 2] + 1)\n"
            i += 3
        }
        return Data(s.utf8)
    }

    /// Binary STL — compact and universally accepted by slicers/CAD tools.
    func stlData() -> Data {
        let triCount = indices.count / 3
        var data = Data(capacity: 84 + triCount * 50)
        data.append(Data(count: 80))                 // unused 80-byte header
        appendLE(UInt32(triCount), to: &data)

        var i = 0
        while i + 2 < indices.count {
            let a = positions[Int(indices[i])]
            let b = positions[Int(indices[i + 1])]
            let c = positions[Int(indices[i + 2])]
            let raw = simd_cross(b - a, c - a)
            let n = simd_length(raw) > 1e-12 ? normalize(raw) : SIMD3<Float>(0, 0, 1)
            for v in [n, a, b, c] {
                appendLE(v.x, to: &data); appendLE(v.y, to: &data); appendLE(v.z, to: &data)
            }
            appendLE(UInt16(0), to: &data)           // attribute byte count
            i += 3
        }
        return data
    }

    private func appendLE<T>(_ value: T, to data: inout Data) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
