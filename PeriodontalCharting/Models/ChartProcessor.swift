import Foundation

struct ChartProcessor {
    static func apply(command: AnnotationCommand, to mouthState: inout [Int: ToothObject]) {
        print("APPLY: \(command)")
        
        let ts = command.teethSelection
        
        if let sAspect = ts.startAspect, let eAspect = ts.endAspect {
            
            let seq = ChartAnatomyResolver.sequence(from: (ts.startTooth.toothNumber, sAspect, ts.startSite),
                                                    to: (ts.endTooth.toothNumber, eAspect, ts.endSite))
            
            let firstValue = command.values.first ?? "0"
            let intValue = Int(firstValue) ?? 0
            let boolVal = firstValue.lowercased() == "true"
            
            for (t, aspect, site) in seq {
                guard mouthState[t] != nil else { continue }
                
                switch command.operation {
                case .probingDepth:
                    if aspect == .outer { mouthState[t]?.probingDepth.outer[site] = intValue }
                    else { mouthState[t]?.probingDepth.inner[site] = intValue }
                case .gingivalMargin:
                    if aspect == .outer { mouthState[t]?.gingivalMargin.outer[site] = intValue }
                    else { mouthState[t]?.gingivalMargin.inner[site] = intValue }
                case .bleeding:
                    if aspect == .outer { mouthState[t]?.bleeding.outer[site] = boolVal }
                    else { mouthState[t]?.bleeding.inner[site] = boolVal }
                case .plaque:
                    if aspect == .outer { mouthState[t]?.plaque.outer[site] = boolVal }
                    else { mouthState[t]?.plaque.inner[site] = boolVal }
                case .missing:
                    mouthState[t]?.missing = true
                default: break
                }
            }
            return
        } else if let sSite = ts.startSite, ts.startTooth.toothNumber == ts.endTooth.toothNumber {
            let eSite = ts.endSite ?? sSite
            let aspectsToIterate: [ChartAspect] = ts.startAspect == nil ? [.outer, .inner] : [ts.startAspect!]
            let t = ts.startTooth.toothNumber
            var valIdx = 0
            
            for aspect in aspectsToIterate {
                for site in min(sSite, eSite)...max(sSite, eSite) {
                    guard mouthState[t] != nil else { continue }
                    let valStr = valIdx < command.values.count ? command.values[valIdx] : "0"
                    valIdx += 1
                    
                    let intValue = Int(valStr) ?? 0
                    let boolVal = valStr.lowercased() == "true"
                    
                    switch command.operation {
                    case .probingDepth:
                        if aspect == .outer { mouthState[t]?.probingDepth.outer[site] = intValue }
                        else { mouthState[t]?.probingDepth.inner[site] = intValue }
                    case .gingivalMargin:
                        if aspect == .outer { mouthState[t]?.gingivalMargin.outer[site] = intValue }
                        else { mouthState[t]?.gingivalMargin.inner[site] = intValue }
                    case .bleeding:
                        if aspect == .outer { mouthState[t]?.bleeding.outer[site] = boolVal }
                        else { mouthState[t]?.bleeding.inner[site] = boolVal }
                    case .plaque:
                        if aspect == .outer { mouthState[t]?.plaque.outer[site] = boolVal }
                        else { mouthState[t]?.plaque.inner[site] = boolVal }
                    case .missing:
                        mouthState[t]?.missing = true
                    default: break
                    }
                }
            }
            return
        } else if ts.startTooth.toothNumber != ts.endTooth.toothNumber {
            let allTeeth = [
                18,17,16,15,14,13,12,11, 21,22,23,24,25,26,27,28,
                48,47,46,45,44,43,42,41, 31,32,33,34,35,36,37,38
            ]
            if let sIdx = allTeeth.firstIndex(of: ts.startTooth.toothNumber),
               let eIdx = allTeeth.firstIndex(of: ts.endTooth.toothNumber) {
                let lower = min(sIdx, eIdx)
                let upper = max(sIdx, eIdx)
                let teethInRange = Array(allTeeth[lower...upper])
                
                var valueIndex = 0
                for t in teethInRange {
                    guard mouthState[t] != nil else { continue }
                    _ = command.aspect ?? .outer
                    
                    let v1 = valueIndex < command.values.count ? command.values[valueIndex] : "False"
                    let v2 = valueIndex + 1 < command.values.count ? command.values[valueIndex + 1] : "False"
                    let v3 = valueIndex + 2 < command.values.count ? command.values[valueIndex + 2] : "False"
                    valueIndex += 3
                    
                    let i1 = Int(v1) ?? 0; let i2 = Int(v2) ?? 0; let i3 = Int(v3) ?? 0
                    let b1 = v1.lowercased() == "true"; let b2 = v2.lowercased() == "true"; let b3 = v3.lowercased() == "true"
                    
                    switch command.operation {
                    case .probingDepth:
                        if let asp = command.aspect {
                            if asp == .outer { mouthState[t]?.probingDepth.outer = [i1, i2, i3] }
                            else { mouthState[t]?.probingDepth.inner = [i1, i2, i3] }
                        } else {
                            mouthState[t]?.probingDepth.outer = [i1, i2, i3]
                            mouthState[t]?.probingDepth.inner = [i1, i2, i3]
                        }
                    case .gingivalMargin:
                        if let asp = command.aspect {
                            if asp == .outer { mouthState[t]?.gingivalMargin.outer = [i1, i2, i3] }
                            else { mouthState[t]?.gingivalMargin.inner = [i1, i2, i3] }
                        } else {
                            mouthState[t]?.gingivalMargin.outer = [i1, i2, i3]
                            mouthState[t]?.gingivalMargin.inner = [i1, i2, i3]
                        }
                    case .bleeding:
                        if let asp = command.aspect {
                            if asp == .outer { mouthState[t]?.bleeding.outer = [b1, b2, b3] }
                            else { mouthState[t]?.bleeding.inner = [b1, b2, b3] }
                        } else {
                            mouthState[t]?.bleeding.outer = [b1, b2, b3]
                            mouthState[t]?.bleeding.inner = [b1, b2, b3]
                        }
                    case .plaque:
                        if let asp = command.aspect {
                            if asp == .outer { mouthState[t]?.plaque.outer = [b1, b2, b3] }
                            else { mouthState[t]?.plaque.inner = [b1, b2, b3] }
                        } else {
                            mouthState[t]?.plaque.outer = [b1, b2, b3]
                            mouthState[t]?.plaque.inner = [b1, b2, b3]
                        }
                    case .missing:
                        mouthState[t]?.missing = true
                    default: break
                    }
                }
            }
            return
        }
        
        let tNum = command.teethSelection.startTooth.toothNumber
        guard mouthState[tNum] != nil else { return }
        
        switch command.operation {
        case .missing:
            mouthState[tNum]?.missing = true
        case .probingDepth:
            let ints = command.values.compactMap { Int($0) }
            if command.aspect == .outer {
                mouthState[tNum]?.probingDepth.outer = ints
            } else {
                mouthState[tNum]?.probingDepth.inner = ints
            }
        case .gingivalMargin:
            let ints = command.values.compactMap { Int($0) }
            if command.aspect == .outer {
                mouthState[tNum]?.gingivalMargin.outer = ints
            } else {
                mouthState[tNum]?.gingivalMargin.inner = ints
            }
        case .bleeding:
            let boolVals = [true, true, true]
            if command.aspect == .outer {
                mouthState[tNum]?.bleeding.outer = boolVals
            } else {
                mouthState[tNum]?.bleeding.inner = boolVals
            }
        case .plaque:
            let boolVals = [true, true, true]
            if command.aspect == .outer {
                mouthState[tNum]?.plaque.outer = boolVals
            } else {
                mouthState[tNum]?.plaque.inner = boolVals
            }
        default:
            break
        }
    }
}

extension ChartProcessor {
    /// Cells where the live *preview* mouth (full confirmed+unconfirmed text)
    /// differs from the *committed* mouth (confirmed text only) — i.e. the
    /// tentative, not-yet-confirmed values. Used to ghost those cells in the chart.
    /// A value that legitimately equals the committed default (e.g. 0) can't be
    /// distinguished from "unset", so it won't ghost — acceptable for a tentative cue.
    static func differingCells(
        preview: [Int: ToothObject], committed: [Int: ToothObject]
    ) -> Set<ChartCellCoordinate> {
        var out = Set<ChartCellCoordinate>()

        func siteCoords<T: Equatable>(
            _ op: AnnotationOperation, tooth: Int,
            _ pv: AspectData<T>, _ cv: AspectData<T>
        ) {
            for site in 0..<3 {
                if site < pv.outer.count, site < cv.outer.count, pv.outer[site] != cv.outer[site] {
                    out.insert(ChartCellCoordinate(toothNumber: tooth, operation: op, aspect: .outer, siteIndex: site))
                }
                if site < pv.inner.count, site < cv.inner.count, pv.inner[site] != cv.inner[site] {
                    out.insert(ChartCellCoordinate(toothNumber: tooth, operation: op, aspect: .inner, siteIndex: site))
                }
            }
        }

        for (num, p) in preview {
            let c = committed[num] ?? ToothObject.create(number: num)
            siteCoords(.probingDepth, tooth: num, p.probingDepth, c.probingDepth)
            siteCoords(.gingivalMargin, tooth: num, p.gingivalMargin, c.gingivalMargin)
            siteCoords(.bleeding, tooth: num, p.bleeding, c.bleeding)
            siteCoords(.plaque, tooth: num, p.plaque, c.plaque)

            // Furcation: optional per-aspect arrays of FurcationClass.
            let pFurcO = p.furcation?.outer ?? [], cFurcO = c.furcation?.outer ?? []
            for site in 0..<max(pFurcO.count, cFurcO.count) where
                (site < pFurcO.count ? pFurcO[site] : nil) != (site < cFurcO.count ? cFurcO[site] : nil) {
                out.insert(ChartCellCoordinate(toothNumber: num, operation: .furcation, aspect: .outer, siteIndex: site))
            }
            let pFurcI = p.furcation?.inner ?? [], cFurcI = c.furcation?.inner ?? []
            for site in 0..<max(pFurcI.count, cFurcI.count) where
                (site < pFurcI.count ? pFurcI[site] : nil) != (site < cFurcI.count ? cFurcI[site] : nil) {
                out.insert(ChartCellCoordinate(toothNumber: num, operation: .furcation, aspect: .inner, siteIndex: site))
            }

            // Single-value shared cells.
            if p.mobility != c.mobility {
                out.insert(ChartCellCoordinate(toothNumber: num, operation: .mobility, aspect: nil, siteIndex: nil))
            }
            if p.implant != c.implant {
                out.insert(ChartCellCoordinate(toothNumber: num, operation: .implant, aspect: nil, siteIndex: nil))
            }
        }
        return out
    }
}
