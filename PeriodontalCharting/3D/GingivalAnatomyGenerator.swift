//
//  GingivalAnatomyGenerator.swift
//  PeriodontalCharting
//
//  The gingiva and alveolar bone are *functions of the chart data*: generated
//  procedurally and regenerated whenever a measurement changes. Teeth stay
//  static; the soft tissue is derived. Ported from the 3DTeeth prototype's
//  GingivaGenerator.swift, retargeted to read this app's actual chart model
//  (`[Int: ToothObject]`, the same dictionary `ChartDashboard` edits and
//  `PatientChart` persists) instead of the prototype's standalone PerioChart.
//
//  Everything is keyed off the CEJ (the zero point for every measurement):
//
//      crown ──────────────  (static tooth mesh)
//      gingival margin  ▔▔▔   = CEJ + margin          ← recession drops this
//      gum band (pink)  ░░░
//      bone crest       ▁▁▁   = CEJ − (2 + bone loss) ← bone loss drops this
//      bone band (beige)███   down to the root apex
//
//  Data-format note: `ToothObject.probingDepth`/`gingivalMargin` store three
//  sites per aspect (`outer` = buccal/labial, `inner` = lingual/palatal), at
//  the same array index convention `ChartDashboard`'s quadrant columns use —
//  index 0 sits toward the *previous* tooth in `DentalArch.fdiOrder`, index 2
//  toward the *next* one. That means the interproximal (papilla) knot between
//  two adjacent teeth is just: neighbour A's site 2 vs neighbour B's site 0 —
//  no mesial/distal handedness bookkeeping required, since the arrays are
//  already arranged in arch-walking order rather than clinical mesial/distal.
//

import Foundation
import RealityKit
import UIKit
import simd

@MainActor
enum GingivalAnatomyGenerator {

    struct Anatomy {
        let gum: ModelEntity
        let bone: ModelEntity
    }

    private static let assumedMeanToothLengthMM: Float = 21
    private static let subdivisions = 6          // Catmull-Rom samples per segment
    nonisolated static let defaultGumOpacity: Float = 0.64

    static func build(from loaded: LoadedTeeth, mouth: [Int: ToothObject],
                      gumOpacity: Float = defaultGumOpacity) -> Anatomy {
        let modelPerMM = calibrate(loaded)

        var gum = MeshBuilder()
        var bone = MeshBuilder()

        for arch in DentalArch.allCases {
            guard let archCentre = loaded.archCentre[arch] else { continue }
            let coronalDir = coronalDirection(for: arch, in: loaded)
            let knots = knots(for: arch, coronalDir: coronalDir, archCentre: archCentre,
                              loaded: loaded, mouth: mouth, modelPerMM: modelPerMM)
            guard knots.count > 1 else { continue }

            let columns = resample(knots, coronalDir: coronalDir, modelPerMM: modelPerMM)
            for side in [Side.buccal, .lingual] {
                fence(columns, side: side, layer: .gum, into: &gum)
                fence(columns, side: side, layer: .bone, into: &bone)
            }
            // Floor joining the buccal and lingual bone walls into a closed trough,
            // so roots read as buried rather than showing through from below/behind.
            floor(columns, level: .base, onBone: true, into: &bone)
            // Same seal one level up, at the crest — where the gum's own two
            // walls meet the bone housing exactly (both use the wide `onBone`
            // offset there, see `fence`). Without this the gum is just two
            // open sheets; this closes it into one solid collar around the root.
            floor(columns, level: .boneCrest, onBone: true, into: &gum)

            // Interproximal papillae, from the original (un-subdivided) knots.
            for knot in knots where knot.isInterproximal {
                let col = Column(knot: knot, coronalDir: coronalDir, modelPerMM: modelPerMM)
                let b = col.point(.buccal, .marginTop, onBone: false)
                let l = col.point(.lingual, .marginTop, onBone: false)
                let peakY = col.y(.buccal, .marginTop) + coronalDir * 1.2 * modelPerMM
                let peak = SIMD3((b.x + l.x) / 2, peakY, (b.z + l.z) / 2)
                gum.addTriangle(b, l, peak, normal: [0, coronalDir, 0])
            }

            // Close the distal openings behind the terminal molars.
            if let first = columns.first { capEnd(first, into: &gum, bone: &bone) }
            if let last = columns.last { capEnd(last, into: &gum, bone: &bone) }
        }

        let gumEntity = ModelEntity(mesh: gum.build(),
                                    materials: [gumMaterial(opacity: gumOpacity)])
        gumEntity.name = "gingiva"
        let boneEntity = ModelEntity(mesh: bone.build(),
                                     materials: [boneMaterial()])
        boneEntity.name = "alveolarBone"
        return Anatomy(gum: gumEntity, bone: boneEntity)
    }

    // MARK: - Cross-section model

    private enum Side { case buccal, lingual }
    private enum Layer { case gum, bone }
    private enum Level { case marginTop, boneCrest, base }

    /// A knot at one arch position: everything the ribbon needs, per side.
    private struct Knot {
        var centre2: SIMD2<Float>
        var outward: SIMD2<Float>
        var cejY: Float
        var apexY: Float
        /// Flat, arch-wide floor level — the same value on every knot (see
        /// `knots(for:...)`) so the bone's underside is one solid, closed plate
        /// instead of a ragged edge that tracks each tooth's own root depth.
        var baseY: Float
        var marginB, marginL: Float     // mm, + coronal
        var boneB, boneL: Float         // mm of bone loss
        var surfB, surfL: Float         // cervical surface offset (gum hugs here)
        var surfBoneB, surfBoneL: Float // widest root offset (+margin) — bone housing
        var isInterproximal: Bool
    }

    /// A resampled cross-section ready to emit geometry.
    private struct Column {
        var centre2: SIMD2<Float>
        var outward: SIMD2<Float>
        var cejY, apexY, baseY: Float
        var marginB, marginL: Float
        var boneB, boneL: Float
        var surfB, surfL: Float
        var surfBoneB, surfBoneL: Float
        var coronalDir, modelPerMM: Float

        init(knot k: Knot, coronalDir: Float, modelPerMM: Float) {
            centre2 = k.centre2; outward = k.outward
            cejY = k.cejY; apexY = k.apexY; baseY = k.baseY
            marginB = k.marginB; marginL = k.marginL
            boneB = k.boneB; boneL = k.boneL
            surfB = k.surfB; surfL = k.surfL
            surfBoneB = k.surfBoneB; surfBoneL = k.surfBoneL
            self.coronalDir = coronalDir; self.modelPerMM = modelPerMM
        }
        init() { centre2 = .zero; outward = SIMD2(0, 1); cejY = 0; apexY = 0; baseY = 0
                 marginB = 0; marginL = 0; boneB = 0; boneL = 0; surfB = 0; surfL = 0
                 surfBoneB = 0; surfBoneL = 0; coronalDir = 1; modelPerMM = 1 }

        func y(_ side: Side, _ level: Level) -> Float {
            let margin = side == .buccal ? marginB : marginL
            let bone = side == .buccal ? boneB : boneL
            switch level {
            case .marginTop: return cejY + coronalDir * margin * modelPerMM
            case .boneCrest: return cejY - coronalDir * (2 + bone) * modelPerMM
            case .base:      return baseY
            }
        }
        /// A ribbon point. `onBone` places it on the bone housing (widest-root
        /// offset); otherwise it hugs the cervical tooth surface (the gum margin).
        func point(_ side: Side, _ level: Level, onBone: Bool) -> SIMD3<Float> {
            let s: Float
            switch (side, onBone) {
            case (.buccal, false):  s = surfB
            case (.buccal, true):   s = surfBoneB
            case (.lingual, false): s = surfL
            case (.lingual, true):  s = surfBoneL
            }
            let h = side == .buccal ? centre2 + outward * s : centre2 - outward * s
            return SIMD3(h.x, y(side, level), h.y)
        }
        func normal(_ side: Side) -> SIMD3<Float> {
            let o = SIMD3(outward.x, 0, outward.y); return side == .buccal ? o : -o
        }
    }

    // MARK: - Knot construction

    private static func knots(for arch: DentalArch, coronalDir: Float, archCentre: SIMD3<Float>,
                              loaded: LoadedTeeth, mouth: [Int: ToothObject], modelPerMM: Float) -> [Knot] {
        let centre2 = SIMD2(archCentre.x, archCentre.z)
        let band = 2.5 * modelPerMM   // cervical window for surface measurement
        let fdis = arch.fdiOrder.filter { loaded.centroid[$0] != nil }

        var knots: [Knot] = []
        for (idx, fdi) in fdis.enumerated() {
            knots.append(toothKnot(fdi, coronalDir: coronalDir, centre2: centre2,
                                   loaded: loaded, mouth: mouth, band: band, modelPerMM: modelPerMM))
            if idx < fdis.count - 1 {
                knots.append(ipKnot(fdis[idx], fdis[idx + 1], coronalDir: coronalDir,
                                    centre2: centre2, loaded: loaded, mouth: mouth, band: band,
                                    modelPerMM: modelPerMM))
            }
        }

        // Dilate the bone housing: a molar's root splays wider than any single
        // radial measurement captures, so let each column inherit the widest
        // housing of its neighbours. This keeps the bone plate outside the roots.
        // Done *before* the distal extension below, over the real teeth only —
        // otherwise a tapered extension tip inherits its neighbour's pre-taper
        // width right back again and never actually closes to a point.
        let raw = knots
        for i in knots.indices {
            let lo = max(0, i - 1), hi = min(raw.count - 1, i + 1)
            knots[i].surfBoneB = (lo...hi).map { raw[$0].surfBoneB }.max() ?? knots[i].surfBoneB
            knots[i].surfBoneL = (lo...hi).map { raw[$0].surfBoneL }.max() ?? knots[i].surfBoneL
        }

        // Extend the ribbon well distal of each terminal molar so the bone and gum
        // wrap behind the last root instead of ending on the tooth. Two steps,
        // tapering to a point, give a smooth pinch around the back of the molar.
        if knots.count >= 2 {
            let f1 = extended(knots[0], from: knots[1], by: 1.2, archCentre: centre2)
            let f2 = extended(knots[0], from: knots[1], by: 2.4, archCentre: centre2)
            let b1 = extended(knots[knots.count - 1], from: knots[knots.count - 2], by: 1.2, archCentre: centre2)
            let b2 = extended(knots[knots.count - 1], from: knots[knots.count - 2], by: 2.4, archCentre: centre2)
            knots.insert(contentsOf: [f2, f1], at: 0)
            knots.append(contentsOf: [b1, b2])
        }

        // Flatten the floor: without this, each column's base sits 2.5mm past
        // its *own* tooth's apex, and since canines/molars root far deeper than
        // incisors, the underside comes out as a ragged, tooth-by-tooth sawtooth
        // instead of a closed base. Push every column down to the single deepest
        // apex in the arch (plus the same margin) so `floor(...)` seals a flat,
        // solid plate — like a model mounted on a base, not an open root trench.
        if let mostApicalY = coronalDir > 0 ? knots.map(\.apexY).min() : knots.map(\.apexY).max() {
            let flatBaseY = mostApicalY - coronalDir * 2.5 * modelPerMM
            for i in knots.indices { knots[i].baseY = flatBaseY }
        }
        return knots
    }

    /// A copy of `base` pushed distally beyond the terminal tooth by `by` tooth spacings,
    /// continuing the arch's curve rather than running off in a straight line. A
    /// straight extrapolation from just the last two knots visibly kinks away from
    /// the arch as soon as it leaves the last real tooth — the wall behind the
    /// terminal molar reads as a separate flat slab bolted onto the curve instead
    /// of a smooth taper. Rotating around the arch centre by the same angular step
    /// observed between `other` and `base` keeps position *and* the outward-facing
    /// direction following that same curvature, so the extension — and the cap
    /// that closes it — blends into the rest of the arch instead of seaming.
    private static func extended(_ base: Knot, from other: Knot, by: Float, archCentre: SIMD2<Float>) -> Knot {
        var e = base
        let baseVec = base.centre2 - archCentre
        let otherVec = other.centre2 - archCentre
        let radius = simd_length(baseVec)
        guard radius > 1e-5 else { return e }

        var delta = atan2(baseVec.y, baseVec.x) - atan2(otherVec.y, otherVec.x)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        let angle = delta * by
        let c = cos(angle), s = sin(angle)
        let rotate: (SIMD2<Float>) -> SIMD2<Float> = { v in SIMD2(v.x * c - v.y * s, v.x * s + v.y * c) }

        e.centre2 = archCentre + rotate(baseVec)
        e.outward = rotate(base.outward)
        e.isInterproximal = false

        // Taper the ribbon's width to nothing over the extension, so the tube
        // pinches to a smooth point instead of ending in an abrupt full-width
        // wall. Even with the curve-following rotation above, a constant-width
        // cap reads as a seam the moment the real, tooth-shaped surface offsets
        // stop and a flat extrapolated width takes over; closing to a point
        // sidesteps that mismatch entirely rather than trying to match it exactly.
        let taper = max(0, 1 - by / 2.4)
        e.surfB *= taper; e.surfL *= taper
        e.surfBoneB *= taper; e.surfBoneL *= taper
        return e
    }

    private static func toothKnot(_ fdi: Int, coronalDir: Float, centre2: SIMD2<Float>,
                                  loaded: LoadedTeeth, mouth: [Int: ToothObject], band: Float,
                                  modelPerMM: Float) -> Knot {
        let g = geometry(fdi: fdi, coronalDir: coronalDir, archCentre: centre2, loaded: loaded)
        let verts = loaded.vertices[fdi] ?? []
        let surf = surfaceOffset(verts, centre2: g.centre2, outward: g.outward, cejY: g.cejY,
                                 band: band, fallback: g.radialHalf)
        let bone = rootSurfaceOffset(verts, centre2: g.centre2, outward: g.outward, cejY: g.cejY,
                                     coronalDir: coronalDir, modelPerMM: modelPerMM,
                                     minimum: surf, fallback: g.radialHalf)
        // Mid-facial site (index 1 of 3) represents the tooth's own knot; the
        // interproximal (index 0/2) sites feed the papilla knots instead.
        // `baseY` starts as this tooth's own apex-relative depth; `knots(for:...)`
        // overwrites it arch-wide once every knot is known, flattening the floor.
        return Knot(centre2: g.centre2, outward: g.outward, cejY: g.cejY, apexY: g.apexY,
                    baseY: g.apexY - coronalDir * 2.5 * modelPerMM,
                    marginB: margin(mouth, fdi, outer: true, site: 1),
                    marginL: margin(mouth, fdi, outer: false, site: 1),
                    boneB: boneLoss(mouth, fdi, outer: true, site: 1),
                    boneL: boneLoss(mouth, fdi, outer: false, site: 1),
                    surfB: surf.buccal, surfL: surf.lingual,
                    surfBoneB: bone.buccal, surfBoneL: bone.lingual, isInterproximal: false)
    }

    private static func ipKnot(_ a: Int, _ b: Int, coronalDir: Float, centre2: SIMD2<Float>,
                               loaded: LoadedTeeth, mouth: [Int: ToothObject], band: Float,
                               modelPerMM: Float) -> Knot {
        let ga = geometry(fdi: a, coronalDir: coronalDir, archCentre: centre2, loaded: loaded)
        let gb = geometry(fdi: b, coronalDir: coronalDir, archCentre: centre2, loaded: loaded)
        let c2 = (ga.centre2 + gb.centre2) / 2
        let outward = normalize(ga.outward + gb.outward)
        let cejY = (ga.cejY + gb.cejY) / 2

        let verts = (loaded.vertices[a] ?? []) + (loaded.vertices[b] ?? [])
        let fallback = (ga.radialHalf + gb.radialHalf) / 2
        let surf = surfaceOffset(verts, centre2: c2, outward: outward, cejY: cejY, band: band,
                                 fallback: fallback)
        let bone = rootSurfaceOffset(verts, centre2: c2, outward: outward, cejY: cejY,
                                     coronalDir: coronalDir, modelPerMM: modelPerMM,
                                     minimum: surf, fallback: fallback)

        // The surface shared by two arch-adjacent teeth is A's "toward next
        // neighbour" site (index 2) and B's "toward previous neighbour" site
        // (index 0) — see the file-level note on the AspectData index
        // convention. Papilla margin reads more coronal than either mid-facial
        // margin, the way a healthy interdental papilla actually sits higher.
        func ipMargin(outer: Bool) -> Float {
            max(margin(mouth, a, outer: outer, site: 2), margin(mouth, b, outer: outer, site: 0)) + 1.0
        }
        func ipBone(outer: Bool) -> Float {
            (boneLoss(mouth, a, outer: outer, site: 2) + boneLoss(mouth, b, outer: outer, site: 0)) / 2
        }

        let apexY = (ga.apexY + gb.apexY) / 2
        return Knot(centre2: c2, outward: outward, cejY: cejY, apexY: apexY,
                    baseY: apexY - coronalDir * 2.5 * modelPerMM,
                    marginB: ipMargin(outer: true), marginL: ipMargin(outer: false),
                    boneB: ipBone(outer: true), boneL: ipBone(outer: false),
                    surfB: surf.buccal, surfL: surf.lingual,
                    surfBoneB: bone.buccal, surfBoneL: bone.lingual, isInterproximal: true)
    }

    /// Measure the tooth surface offset (buccal & lingual) in the cervical band by
    /// projecting vertices onto the outward direction — the runtime stand-in for
    /// the plan's baked surface-distance table.
    private static func surfaceOffset(_ vertices: [SIMD3<Float>], centre2: SIMD2<Float>,
                                      outward: SIMD2<Float>, cejY: Float, band: Float,
                                      fallback: Float) -> (buccal: Float, lingual: Float) {
        var b = -Float.greatestFiniteMagnitude
        var l = -Float.greatestFiniteMagnitude
        for v in vertices where abs(v.y - cejY) < band {
            let d = simd_dot(SIMD2(v.x, v.z) - centre2, outward)
            b = max(b, d); l = max(l, -d)
        }
        let eps = fallback * 0.08
        let buccal = b > 0 ? b + eps : fallback
        let lingual = l > 0 ? l + eps : fallback
        return (buccal, lingual)
    }

    /// Measure the *widest* buccal/lingual extent over the whole root (apical of
    /// the CEJ) and add a bone-thickness margin, so the alveolar housing fully
    /// encloses even the splayed roots of the molars.
    private static func rootSurfaceOffset(_ vertices: [SIMD3<Float>], centre2: SIMD2<Float>,
                                          outward: SIMD2<Float>, cejY: Float, coronalDir: Float,
                                          modelPerMM: Float, minimum: (buccal: Float, lingual: Float),
                                          fallback: Float) -> (buccal: Float, lingual: Float) {
        var b = -Float.greatestFiniteMagnitude
        var l = -Float.greatestFiniteMagnitude
        for v in vertices where coronalDir * (v.y - cejY) < 0 {   // apical of the CEJ
            let d = simd_dot(SIMD2(v.x, v.z) - centre2, outward)
            b = max(b, d); l = max(l, -d)
        }
        let margin = 2.6 * modelPerMM
        let buccal = (b > 0 ? b : fallback) + margin
        let lingual = (l > 0 ? l : fallback) + margin
        // Never inside the cervical (gum) offset.
        return (max(buccal, minimum.buccal + margin), max(lingual, minimum.lingual + margin))
    }

    // MARK: - Catmull-Rom resampling

    private static func resample(_ knots: [Knot], coronalDir: Float, modelPerMM: Float) -> [Column] {
        guard knots.count > 1 else { return knots.map { Column(knot: $0, coronalDir: coronalDir, modelPerMM: modelPerMM) } }
        var out: [Column] = []
        let n = knots.count
        for i in 0..<(n - 1) {
            let k0 = knots[max(0, i - 1)], k1 = knots[i], k2 = knots[i + 1], k3 = knots[min(n - 1, i + 2)]
            for s in 0..<subdivisions {
                let t = Float(s) / Float(subdivisions)
                out.append(interpolate(k0, k1, k2, k3, t, coronalDir: coronalDir, modelPerMM: modelPerMM))
            }
        }
        out.append(Column(knot: knots[n - 1], coronalDir: coronalDir, modelPerMM: modelPerMM))
        return out
    }

    private static func interpolate(_ k0: Knot, _ k1: Knot, _ k2: Knot, _ k3: Knot,
                                    _ t: Float, coronalDir: Float, modelPerMM: Float) -> Column {
        func cr(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
            let t2 = t * t, t3 = t2 * t
            return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        var col = Column()
        col.coronalDir = coronalDir; col.modelPerMM = modelPerMM
        col.centre2 = SIMD2(cr(k0.centre2.x, k1.centre2.x, k2.centre2.x, k3.centre2.x),
                            cr(k0.centre2.y, k1.centre2.y, k2.centre2.y, k3.centre2.y))
        let o = SIMD2(cr(k0.outward.x, k1.outward.x, k2.outward.x, k3.outward.x),
                      cr(k0.outward.y, k1.outward.y, k2.outward.y, k3.outward.y))
        col.outward = simd_length(o) > 1e-5 ? normalize(o) : k1.outward
        col.cejY = cr(k0.cejY, k1.cejY, k2.cejY, k3.cejY)
        col.apexY = cr(k0.apexY, k1.apexY, k2.apexY, k3.apexY)
        col.baseY = cr(k0.baseY, k1.baseY, k2.baseY, k3.baseY)
        col.marginB = cr(k0.marginB, k1.marginB, k2.marginB, k3.marginB)
        col.marginL = cr(k0.marginL, k1.marginL, k2.marginL, k3.marginL)
        col.boneB = cr(k0.boneB, k1.boneB, k2.boneB, k3.boneB)
        col.boneL = cr(k0.boneL, k1.boneL, k2.boneL, k3.boneL)
        col.surfB = cr(k0.surfB, k1.surfB, k2.surfB, k3.surfB)
        col.surfL = cr(k0.surfL, k1.surfL, k2.surfL, k3.surfL)
        col.surfBoneB = cr(k0.surfBoneB, k1.surfBoneB, k2.surfBoneB, k3.surfBoneB)
        col.surfBoneL = cr(k0.surfBoneL, k1.surfBoneL, k2.surfBoneL, k3.surfBoneL)
        return col
    }

    // MARK: - Geometry helpers

    private struct Geom {
        var centre2: SIMD2<Float>
        var outward: SIMD2<Float>
        var radialHalf: Float
        var cejY: Float
        var apexY: Float
    }

    private static func geometry(fdi: Int, coronalDir: Float, archCentre: SIMD2<Float>,
                                 loaded: LoadedTeeth) -> Geom {
        let bounds = loaded.toothEntity[fdi]!.visualBounds(relativeTo: loaded.modelRoot)
        let c = bounds.center, ext = bounds.extents
        let centre2 = SIMD2(c.x, c.z)
        var outward = centre2 - archCentre
        outward = simd_length(outward) > 1e-5 ? normalize(outward) : SIMD2(0, 1)

        let crownY = c.y + coronalDir * ext.y / 2
        let apexY  = c.y - coronalDir * ext.y / 2
        // Prefer the asset's baked CEJ marker; fall back to the Wheeler ratio
        // (CEJ ≈ 0.61 of tooth length from the apex, per the build plan).
        let markerY = loaded.cejY[fdi]
        let inRange = markerY.map { min(crownY, apexY) <= $0 && $0 <= max(crownY, apexY) } ?? false
        let cejY = inRange ? markerY! : apexY + 0.61 * (crownY - apexY)
        let radialHalf = 0.5 * (abs(ext.x * outward.x) + abs(ext.z * outward.y))
        return Geom(centre2: centre2, outward: outward,
                    radialHalf: max(radialHalf, ext.x * 0.25), cejY: cejY, apexY: apexY)
    }

    // MARK: - Data → millimetres

    /// `outer` = buccal/labial, `inner` = lingual/palatal — same convention as
    /// `ToothObject`. `site` is 0/1/2 along `DentalArch.fdiOrder`.
    private static func margin(_ mouth: [Int: ToothObject], _ fdi: Int, outer: Bool, site: Int) -> Float {
        guard let tooth = mouth[fdi], !tooth.missing else { return 1 }
        let arr = outer ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner
        guard site < arr.count else { return 1 }
        return Float(arr[site])
    }

    private static func boneLoss(_ mouth: [Int: ToothObject], _ fdi: Int, outer: Bool, site: Int) -> Float {
        guard let tooth = mouth[fdi], !tooth.missing else { return 3 }   // some ridge resorption
        let pd = outer ? tooth.probingDepth.outer : tooth.probingDepth.inner
        let gm = outer ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner
        guard site < pd.count, site < gm.count else { return 0 }
        let cal = pd[site] - gm[site]   // attachment level, same formula as ToothObject.attachmentLevel
        return max(0, Float(cal) - 1)
    }

    // MARK: - Calibration & materials

    private static func calibrate(_ loaded: LoadedTeeth) -> Float {
        let lengths = loaded.toothEntity.values.map {
            $0.visualBounds(relativeTo: loaded.modelRoot).extents.y
        }
        let mean = lengths.isEmpty ? 0.01 : lengths.reduce(0, +) / Float(lengths.count)
        return mean / assumedMeanToothLengthMM
    }

    private static func coronalDirection(for arch: DentalArch, in loaded: LoadedTeeth) -> Float {
        let other: DentalArch = arch == .maxilla ? .mandible : .maxilla
        guard let mine = loaded.archCentre[arch], let theirs = loaded.archCentre[other] else {
            return arch == .maxilla ? -1 : 1
        }
        return theirs.y >= mine.y ? 1 : -1
    }

    /// Translucent coral gum, so the bone crest and buried roots read through it
    /// — the look of the reference CBCT rendering. `opacity` is exposed so the
    /// scene view can drive it live from a slider without rebuilding the mesh.
    private static func gumMaterial(opacity: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.87, green: 0.40, blue: 0.45, alpha: 1))
        m.roughness = 0.6
        m.metallic = 0.0
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        m.faceCulling = .none
        return m
    }

    /// Re-tint the gum entity's existing material in place — a cheap,
    /// geometry-free update for live slider dragging.
    static func setGumOpacity(_ opacity: Float, on gum: ModelEntity) {
        guard var material = gum.model?.materials.first as? PhysicallyBasedMaterial else { return }
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        gum.model?.materials = [material]
    }

    private static func boneMaterial() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.85, green: 0.78, blue: 0.66, alpha: 1))
        m.roughness = 0.85
        m.metallic = 0.0
        m.faceCulling = .none
        return m
    }

    // MARK: - Ribbon emission

    /// Cap a terminal column's distal face so the ribbons don't end in open flaps.
    private static func capEnd(_ c: Column, into gum: inout MeshBuilder, bone: inout MeshBuilder) {
        gum.addQuadAutoNormal(c.point(.buccal, .marginTop, onBone: false),
                              c.point(.lingual, .marginTop, onBone: false),
                              c.point(.lingual, .boneCrest, onBone: true),
                              c.point(.buccal, .boneCrest, onBone: true))
        bone.addQuadAutoNormal(c.point(.buccal, .boneCrest, onBone: true),
                               c.point(.lingual, .boneCrest, onBone: true),
                               c.point(.lingual, .base, onBone: true),
                               c.point(.buccal, .base, onBone: true))
    }

    /// Seal the buccal and lingual walls together at one level, bridging them
    /// into a closed, solid cross-section instead of two open sheets with
    /// nothing between them. Used for the bone's base (the alveolar housing
    /// becomes a solid mass with the roots buried inside) and for the gum's
    /// crest (so the gum band itself is a solid collar around the root, not
    /// just two thin translucent walls with an empty gap between them).
    private static func floor(_ columns: [Column], level: Level, onBone: Bool,
                              into builder: inout MeshBuilder) {
        for i in 0..<(columns.count - 1) {
            let c0 = columns[i], c1 = columns[i + 1]
            builder.addQuadAutoNormal(c0.point(.buccal, level, onBone: onBone),
                                      c1.point(.buccal, level, onBone: onBone),
                                      c1.point(.lingual, level, onBone: onBone),
                                      c0.point(.lingual, level, onBone: onBone))
        }
    }

    private static func fence(_ columns: [Column], side: Side, layer: Layer,
                              into builder: inout MeshBuilder) {
        for i in 0..<(columns.count - 1) {
            let c0 = columns[i], c1 = columns[i + 1]
            let n = normalize(c0.normal(side) + c1.normal(side))
            let (t0, t1, b0, b1): (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
            if layer == .gum {
                // Margin hugs the tooth; crest meets the bone housing.
                t0 = c0.point(side, .marginTop, onBone: false)
                t1 = c1.point(side, .marginTop, onBone: false)
                b0 = c0.point(side, .boneCrest, onBone: true)
                b1 = c1.point(side, .boneCrest, onBone: true)
            } else {
                t0 = c0.point(side, .boneCrest, onBone: true)
                t1 = c1.point(side, .boneCrest, onBone: true)
                b0 = c0.point(side, .base, onBone: true)
                b1 = c1.point(side, .base, onBone: true)
            }
            builder.addQuad(t0, t1, b1, b0, normal: n)
        }
    }
}

// MARK: - Tiny triangle-mesh accumulator

private struct MeshBuilder {
    private var positions: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []
    private var indices: [UInt32] = []

    mutating func addTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                              normal: SIMD3<Float>) {
        let base = UInt32(positions.count)
        positions.append(contentsOf: [a, b, c])
        normals.append(contentsOf: [normal, normal, normal])
        indices.append(contentsOf: [base, base + 1, base + 2])
    }

    mutating func addQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                          _ d: SIMD3<Float>, normal: SIMD3<Float>) {
        addTriangle(a, b, d, normal: normal)
        addTriangle(b, c, d, normal: normal)
    }

    mutating func addTriangleAutoNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        let raw = simd_cross(b - a, c - a)
        let n = simd_length(raw) > 1e-8 ? normalize(raw) : SIMD3<Float>(0, 1, 0)
        addTriangle(a, b, c, normal: n)
    }

    mutating func addQuadAutoNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                                    _ d: SIMD3<Float>) {
        addTriangleAutoNormal(a, b, d)
        addTriangleAutoNormal(b, c, d)
    }

    func build() -> MeshResource {
        guard !positions.isEmpty else { return .generateBox(size: 0.0001) }
        var descriptor = MeshDescriptor(name: "tissue")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: 0.0001)
    }
}
