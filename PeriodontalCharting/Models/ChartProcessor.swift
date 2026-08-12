import Foundation

struct ChartProcessor {
    static func apply(command: AnnotationCommand, to mouthState: inout [Int: ToothObject]) {
        let old17PD = mouthState[17]?.probingDepth
        let old47PD = mouthState[47]?.probingDepth
        
        print("ChartProcessor.apply: tooth=\(command.teethSelection.startTooth.toothNumber) to \(command.teethSelection.endTooth.toothNumber), metric=\(command.operation), aspect=\(String(describing: command.aspect)), startSite=\(String(describing: command.teethSelection.startSite)), endSite=\(String(describing: command.teethSelection.endSite)), values=\(command.values)")
        
        // print("APPLY: \(command)")
        
        let ts = command.teethSelection
        if let sAspect = ts.startAspect, let eAspect = ts.endAspect {
            
            let seq = ChartAnatomyResolver.sequence(from: (ts.startTooth.toothNumber, sAspect, ts.startSite),
                                                    to: (ts.endTooth.toothNumber, eAspect, ts.endSite))
            
            let isBroadcast = command.values.count == 1
            var valueIndex = 0
            
            for (t, aspect, site) in seq {
                guard mouthState[t] != nil else { continue }
                
                let valStr = isBroadcast ? (command.values.first ?? "0") : (valueIndex < command.values.count ? command.values[valueIndex] : "0")
                if !isBroadcast { valueIndex += 1 }
                
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
                    let isMissing = command.values.first?.lowercased() == "true"
                    let wasMissing = mouthState[t]?.missing ?? false
                    print("👉 ChartProcessor (aspect) setting missing for \(t) to \(isMissing) (was \(wasMissing))")
                    mouthState[t]?.missing = isMissing
                    if !isMissing && wasMissing {
                        mouthState[t]?.probingDepth = AspectData(outer: [0,0,0], inner: [0,0,0])
                        mouthState[t]?.gingivalMargin = AspectData(outer: [0,0,0], inner: [0,0,0])
                        mouthState[t]?.mobility = .zero
                        mouthState[t]?.bleeding = AspectData(outer: [false,false,false], inner: [false,false,false])
                        mouthState[t]?.plaque = AspectData(outer: [false,false,false], inner: [false,false,false])
                        mouthState[t]?.implant = false
                        mouthState[t]?.furcation = ToothObject.create(number: t).furcation
                    }
                case .mobility:
                    if let mClass = MobilityClass(rawValue: intValue) {
                        mouthState[t]?.mobility = mClass
                    }
                case .implant:
                    mouthState[t]?.implant = boolVal
                    if boolVal && mouthState[t]?.missing == true {
                        mouthState[t]?.missing = false
                        mouthState[t]?.probingDepth = AspectData(outer: [0,0,0], inner: [0,0,0])
                        mouthState[t]?.gingivalMargin = AspectData(outer: [0,0,0], inner: [0,0,0])
                        mouthState[t]?.mobility = .zero
                        mouthState[t]?.bleeding = AspectData(outer: [false,false,false], inner: [false,false,false])
                        mouthState[t]?.plaque = AspectData(outer: [false,false,false], inner: [false,false,false])
                        mouthState[t]?.furcation = ToothObject.create(number: t).furcation
                    }
                case .furcation:
                    if let fClass = FurcationClass(rawValue: intValue) {
                        if aspect == .outer {
                            if (mouthState[t]?.furcation?.outer.count ?? 0) > 0 {
                                mouthState[t]?.furcation?.outer[0] = fClass
                            }
                        } else {
                            if let innerCount = mouthState[t]?.furcation?.inner.count, innerCount > 0 {
                                if innerCount == 2 {
                                    let innerSite = (site == 2) ? 1 : 0
                                    mouthState[t]?.furcation?.inner[innerSite] = fClass
                                } else {
                                    mouthState[t]?.furcation?.inner[0] = fClass
                                }
                            }
                        }
                    }
                }
            }
            return
        } else if let sSite = ts.startSite, ts.startTooth.toothNumber == ts.endTooth.toothNumber {
            let eSite = ts.endSite ?? sSite
            
            let aspectsToIterate: [ChartAspect]
            if let a = command.aspect {
                aspectsToIterate = [a]
            } else if let sa = ts.startAspect {
                aspectsToIterate = [sa]
            } else {
                aspectsToIterate = [.outer, .inner]
            }
            
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
                var teethInRange = Array(allTeeth[lower...upper])
                if sIdx > eIdx {
                    teethInRange.reverse()
                }
                
                let isSiteBased = [.probingDepth, .gingivalMargin, .bleeding, .plaque].contains(command.operation)
                
                if isSiteBased {
                    let aspectsToIterate: [ChartAspect] = command.aspect != nil ? [command.aspect!] : [.outer, .inner]
                    let isBroadcast = command.values.count == 1
                    
                    if isBroadcast && ts.startSite != nil && ts.startSite == ts.endSite {
                        // Apply the single value to the specific site on EVERY tooth in the range
                        for aspect in aspectsToIterate {
                            let site = ts.startSite!
                            let valStr = command.values[0]
                            let intValue = Int(valStr) ?? 0
                            let boolVal = valStr.lowercased() == "true"
                            
                            for t in teethInRange {
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
                                default: break
                                }
                            }
                        }
                    } else if isBroadcast && ts.startSite == nil && ts.endSite == nil {
                        // Apply the single value to ALL sites on EVERY tooth in the range
                        for aspect in aspectsToIterate {
                            let valStr = command.values[0]
                            let intValue = Int(valStr) ?? 0
                            let boolVal = valStr.lowercased() == "true"
                            
                            for t in teethInRange {
                                guard mouthState[t] != nil else { continue }
                                
                                for site in 0..<3 {
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
                                    default: break
                                    }
                                }
                            }
                        }
                    } else {
                        for aspect in aspectsToIterate {
                            let seq = ChartAnatomyResolver.sequence(
                                from: (ts.startTooth.toothNumber, aspect, ts.startSite),
                                to: (ts.endTooth.toothNumber, aspect, ts.endSite)
                            )
                            
                            var valueIndex = 0
                            for item in seq {
                                let t = item.0
                                let a = item.1
                                let site = item.2
                                
                                guard mouthState[t] != nil else { continue }
                                
                                let valStr = isBroadcast ? command.values[0] : (valueIndex < command.values.count ? command.values[valueIndex] : "0")
                                if !isBroadcast { valueIndex += 1 }
                                
                                let intValue = Int(valStr) ?? 0
                                let boolVal = valStr.lowercased() == "true"
                                
                                switch command.operation {
                                case .probingDepth:
                                    if a == .outer { mouthState[t]?.probingDepth.outer[site] = intValue }
                                    else { mouthState[t]?.probingDepth.inner[site] = intValue }
                                case .gingivalMargin:
                                    if a == .outer { mouthState[t]?.gingivalMargin.outer[site] = intValue }
                                    else { mouthState[t]?.gingivalMargin.inner[site] = intValue }
                                case .bleeding:
                                    if a == .outer { mouthState[t]?.bleeding.outer[site] = boolVal }
                                    else { mouthState[t]?.bleeding.inner[site] = boolVal }
                                case .plaque:
                                    if a == .outer { mouthState[t]?.plaque.outer[site] = boolVal }
                                    else { mouthState[t]?.plaque.inner[site] = boolVal }
                                default: break
                                }
                            }
                        }
                    }
                } else {
                    // Tooth-based metrics
                    var valueIndex = 0
                    let isBroadcast = command.values.count == 1
                    for t in teethInRange {
                        guard mouthState[t] != nil else { continue }
                        let valStr = isBroadcast ? command.values[0] : (valueIndex < command.values.count ? command.values[valueIndex] : "0")
                        if !isBroadcast { valueIndex += 1 }
                        
                        let i1 = Int(valStr) ?? 0
                        let b1 = valStr.lowercased() == "true"
                        
                        switch command.operation {
                        case .missing:
                            let wasMissing = mouthState[t]?.missing ?? false
                            print("👉 ChartProcessor setting missing for \(t) to \(b1) (was \(wasMissing))")
                            mouthState[t]?.missing = b1
                            if !b1 && wasMissing {
                                mouthState[t]?.probingDepth = AspectData(outer: [0,0,0], inner: [0,0,0])
                                mouthState[t]?.gingivalMargin = AspectData(outer: [0,0,0], inner: [0,0,0])
                                mouthState[t]?.mobility = .zero
                                mouthState[t]?.bleeding = AspectData(outer: [false,false,false], inner: [false,false,false])
                                mouthState[t]?.plaque = AspectData(outer: [false,false,false], inner: [false,false,false])
                                mouthState[t]?.implant = false
                                mouthState[t]?.furcation = ToothObject.create(number: t).furcation
                            }
                        case .mobility:
                            if let mClass = MobilityClass(rawValue: i1) {
                                mouthState[t]?.mobility = mClass
                            }
                        case .implant:
                            mouthState[t]?.implant = b1
                            if b1 && mouthState[t]?.missing == true {
                                mouthState[t]?.missing = false
                                mouthState[t]?.probingDepth = AspectData(outer: [0,0,0], inner: [0,0,0])
                                mouthState[t]?.gingivalMargin = AspectData(outer: [0,0,0], inner: [0,0,0])
                                mouthState[t]?.mobility = .zero
                                mouthState[t]?.bleeding = AspectData(outer: [false,false,false], inner: [false,false,false])
                                mouthState[t]?.plaque = AspectData(outer: [false,false,false], inner: [false,false,false])
                                mouthState[t]?.furcation = ToothObject.create(number: t).furcation
                            }
                        case .furcation:
                            if let fClass = FurcationClass(rawValue: i1) {
                                if let asp = command.aspect {
                                    if asp == .outer {
                                        if (mouthState[t]?.furcation?.outer.count ?? 0) > 0 { mouthState[t]?.furcation?.outer = [fClass] }
                                    } else {
                                        if let innerCount = mouthState[t]?.furcation?.inner.count, innerCount > 0 {
                                            mouthState[t]?.furcation?.inner = Array(repeating: fClass, count: innerCount)
                                        }
                                    }
                                } else {
                                    if (mouthState[t]?.furcation?.outer.count ?? 0) > 0 { mouthState[t]?.furcation?.outer = [fClass] }
                                    if let innerCount = mouthState[t]?.furcation?.inner.count, innerCount > 0 {
                                        mouthState[t]?.furcation?.inner = Array(repeating: fClass, count: innerCount)
                                    }
                                }
                            }
                        default: break
                        }
                    }
                }
            }
            return
        }
        
        let tNum = command.teethSelection.startTooth.toothNumber
        guard mouthState[tNum] != nil else { return }
        
        switch command.operation {
        case .missing:
            let val = command.values.first?.lowercased() ?? "true"
            let isMissing = val == "true"
            let wasMissing = mouthState[tNum]?.missing ?? false
            print("👉 ChartProcessor single tooth setting missing for \(tNum) to \(isMissing) (was \(wasMissing))")
            mouthState[tNum]?.missing = isMissing
            if !isMissing && wasMissing {
                mouthState[tNum]?.probingDepth = AspectData(outer: [0,0,0], inner: [0,0,0])
                mouthState[tNum]?.gingivalMargin = AspectData(outer: [0,0,0], inner: [0,0,0])
                mouthState[tNum]?.mobility = .zero
                mouthState[tNum]?.bleeding = AspectData(outer: [false,false,false], inner: [false,false,false])
                mouthState[tNum]?.plaque = AspectData(outer: [false,false,false], inner: [false,false,false])
                mouthState[tNum]?.implant = false
                mouthState[tNum]?.furcation = ToothObject.create(number: tNum).furcation
            }
        case .mobility:
            if let first = command.values.first, let i1 = Int(first), let mClass = MobilityClass(rawValue: i1) {
                mouthState[tNum]?.mobility = mClass
            }
        case .implant:
            let val = command.values.first?.lowercased() ?? "true"
            let isImplant = val == "true"
            mouthState[tNum]?.implant = isImplant
            if isImplant && mouthState[tNum]?.missing == true {
                mouthState[tNum]?.missing = false
                mouthState[tNum]?.probingDepth = AspectData(outer: [0,0,0], inner: [0,0,0])
                mouthState[tNum]?.gingivalMargin = AspectData(outer: [0,0,0], inner: [0,0,0])
                mouthState[tNum]?.mobility = .zero
                mouthState[tNum]?.bleeding = AspectData(outer: [false,false,false], inner: [false,false,false])
                mouthState[tNum]?.plaque = AspectData(outer: [false,false,false], inner: [false,false,false])
                mouthState[tNum]?.furcation = ToothObject.create(number: tNum).furcation
            }
        case .furcation:
            if let first = command.values.first, let i1 = Int(first), let fClass = FurcationClass(rawValue: i1) {
                if command.aspect == .outer {
                    if (mouthState[tNum]?.furcation?.outer.count ?? 0) > 0 { mouthState[tNum]?.furcation?.outer = [fClass] }
                } else if command.aspect == .inner {
                    if let innerCount = mouthState[tNum]?.furcation?.inner.count, innerCount > 0 {
                        mouthState[tNum]?.furcation?.inner = Array(repeating: fClass, count: innerCount)
                    }
                } else {
                    if (mouthState[tNum]?.furcation?.outer.count ?? 0) > 0 { mouthState[tNum]?.furcation?.outer = [fClass] }
                    if let innerCount = mouthState[tNum]?.furcation?.inner.count, innerCount > 0 {
                        mouthState[tNum]?.furcation?.inner = Array(repeating: fClass, count: innerCount)
                    }
                }
            }
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
            } else if command.aspect == .inner {
                mouthState[tNum]?.bleeding.inner = boolVals
            } else {
                mouthState[tNum]?.bleeding.outer = boolVals
                mouthState[tNum]?.bleeding.inner = boolVals
            }
        case .plaque:
            let boolVals = [true, true, true]
            if command.aspect == .outer {
                mouthState[tNum]?.plaque.outer = boolVals
            } else if command.aspect == .inner {
                mouthState[tNum]?.plaque.inner = boolVals
            } else {
                mouthState[tNum]?.plaque.outer = boolVals
                mouthState[tNum]?.plaque.inner = boolVals
            }
        }
        
        let new17PD = mouthState[17]?.probingDepth
        if old17PD != new17PD {
            print("🚨 TOOTH 17 PD CHANGED BY: \(command.operation) \(command.aspect)")
            print("  Old: \(String(describing: old17PD))")
            print("  New: \(String(describing: new17PD))")
        }
        
        let new47PD = mouthState[47]?.probingDepth
        if old47PD != new47PD {
            print("🚨 TOOTH 47 PD CHANGED BY: \(command.operation) \(String(describing: command.aspect))")
            print("  Old: \(String(describing: old47PD))")
            print("  New: \(String(describing: new47PD))")
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
