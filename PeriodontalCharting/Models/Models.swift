import SwiftUI
import Combine

enum MobilityClass: Int, CaseIterable, Codable {
    case zero = 0
    case one = 1
    case two = 2
    case three = 3
}

enum FurcationClass: Int, CaseIterable, Codable {
    case zero = 0
    case one = 1
    case two = 2
    case three = 3
}

struct FurcationData: Equatable, Codable {
    var outer: [FurcationClass]
    var inner: [FurcationClass]
}

struct AspectData<T: Equatable & Codable>: Equatable, Codable {
    var outer: [T]
    var inner: [T]
}

struct ToothObject: Identifiable, Equatable, Codable {
    var id = UUID()
    var toothNumber: Int
    var probingDepth: AspectData<Int> = AspectData(outer: [0,0,0], inner: [0,0,0])
    var gingivalMargin: AspectData<Int> = AspectData(outer: [0,0,0], inner: [0,0,0])
    var mobility: MobilityClass = .zero
    var furcation: FurcationData? = nil
    var bleeding: AspectData<Bool> = AspectData(outer: [false,false,false], inner: [false,false,false])
    var plaque: AspectData<Bool> = AspectData(outer: [false,false,false], inner: [false,false,false])
    var missing: Bool = false
    var implant: Bool = false
    
    var attachmentLevel: AspectData<Int> {
        guard probingDepth.outer.count == gingivalMargin.outer.count,
              probingDepth.inner.count == gingivalMargin.inner.count else {
            return AspectData(outer: [], inner: [])
        }
        let outerCAL = zip(probingDepth.outer, gingivalMargin.outer).map { $0 - $1 }
        let innerCAL = zip(probingDepth.inner, gingivalMargin.inner).map { $0 - $1 }
        return AspectData(outer: outerCAL, inner: innerCAL)
    }
}

struct TeethSelection: Equatable {
    var startTooth: ToothObject
    var startAspect: ChartAspect?
    var startSite: Int?
    
    var endTooth: ToothObject
    var endAspect: ChartAspect?
    var endSite: Int?
    
    var expectedSlots: Int {
        if let ss = startSite, let es = endSite, startTooth == endTooth {
            let aspectMultiplier = (startAspect == nil) ? 2 : 1
            let siteDist = abs(ss - es) + 1
            return siteDist * aspectMultiplier
        }
        
        if let sa = startAspect, let ea = endAspect {
            return ChartAnatomyResolver.sequence(from: (startTooth.toothNumber, sa, startSite), to: (endTooth.toothNumber, ea, endSite)).count
        }
        
        if startTooth.toothNumber != endTooth.toothNumber {
            let allTeeth = [
                18,17,16,15,14,13,12,11, 21,22,23,24,25,26,27,28,
                48,47,46,45,44,43,42,41, 31,32,33,34,35,36,37,38
            ]
            if let sIdx = allTeeth.firstIndex(of: startTooth.toothNumber),
               let eIdx = allTeeth.firstIndex(of: endTooth.toothNumber) {
                let lower = min(sIdx, eIdx)
                let upper = max(sIdx, eIdx)
                return (upper - lower + 1) * 3
            }
        }
        
        return 3
    }
}

struct ChartAnatomyResolver {
    static func resolve(anatomy: AnatomyType, for tooth: Int, currentAspect: ChartAspect) -> (aspect: ChartAspect?, site: Int?)? {
        let isRight = (11...18).contains(tooth) || (41...48).contains(tooth)
        
        let aspect: ChartAspect?
        switch anatomy {
        case .mesioBuccal, .distoBuccal, .buccal, .labial:
            aspect = .outer
        case .mesioLingual, .distoLingual, .mesioPalatal, .distoPalatal, .lingual, .palatal:
            aspect = .inner
        case .mesial, .distal:
            aspect = currentAspect
        default:
            return nil
        }
        
        let isMesial: Bool
        switch anatomy {
        case .mesioBuccal, .mesioLingual, .mesioPalatal, .mesial: isMesial = true
        case .distoBuccal, .distoLingual, .distoPalatal, .distal: isMesial = false
        case .buccal, .labial, .lingual, .palatal:
            return (aspect, 1)
        default: return nil
        }
        
        let siteIndex: Int
        if isRight {
            siteIndex = isMesial ? 2 : 0
        } else {
            siteIndex = isMesial ? 0 : 2
        }
        
        return (aspect, siteIndex)
    }
    
    static func sequence(from start: (Int, ChartAspect, Int?), to end: (Int, ChartAspect, Int?)) -> [(Int, ChartAspect, Int)] {
        let allTeeth = [
            18,17,16,15,14,13,12,11, 21,22,23,24,25,26,27,28,
            48,47,46,45,44,43,42,41, 31,32,33,34,35,36,37,38
        ]
        
        var flat: [(Int, ChartAspect, Int)] = []
        let aspects: [ChartAspect] = start.1 == end.1 ? [start.1] : [ChartAspect.outer, ChartAspect.inner]
        
        for aspect in aspects {
            for t in allTeeth {
                for s in 0..<3 {
                    flat.append((t, aspect, s))
                }
            }
        }
        
        var startIndices: [Int] = []
        if let sSite = start.2 {
            if let idx = flat.firstIndex(where: { $0.0 == start.0 && $0.1 == start.1 && $0.2 == sSite }) {
                startIndices.append(idx)
            }
        } else {
            startIndices = flat.enumerated().filter({ $0.element.0 == start.0 && $0.element.1 == start.1 }).map { $0.offset }
        }
        
        var endIndices: [Int] = []
        if let eSite = end.2 {
            if let idx = flat.firstIndex(where: { $0.0 == end.0 && $0.1 == end.1 && $0.2 == eSite }) {
                endIndices.append(idx)
            }
        } else {
            endIndices = flat.enumerated().filter({ $0.element.0 == end.0 && $0.element.1 == end.1 }).map { $0.offset }
        }
        
        guard let minStart = startIndices.min(), let maxStart = startIndices.max(),
              let minEnd = endIndices.min(), let maxEnd = endIndices.max() else {
            return []
        }
        
        let lower = min(minStart, minEnd)
        let upper = max(maxStart, maxEnd)
        return Array(flat[lower...upper])
    }
}

enum AnnotationOperation: Hashable {
    case probingDepth
    case gingivalMargin
    case mobility
    case furcation
    case bleeding
    case plaque
    case missing
    case implant
    
    var displayName: String {
        switch self {
        case .probingDepth: return "Probing Depth"
        case .gingivalMargin: return "Gingival Margin"
        case .mobility: return "Mobility"
        case .furcation: return "Furcation"
        case .bleeding: return "Bleeding"
        case .plaque: return "Plaque"
        case .missing: return "Missing"
        case .implant: return "Implant"
        }
    }
}

struct AnnotationCommand: Equatable {
    var operation: AnnotationOperation
    var teethSelection: TeethSelection
    var aspect: ChartAspect?
    var values: [String]
}

enum ChartAspect: Hashable {
    case outer
    case inner
}

struct ChartCellCoordinate: Hashable {
    var toothNumber: Int
    var operation: AnnotationOperation
    var aspect: ChartAspect? // nil for shared grids like Implant, Mobility
    var siteIndex: Int?      // 0, 1, 2 for mesial, mid, distal. nil for single-value cells
}

class ChartSelectionModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    
    @Published var selectedCells: Set<ChartCellCoordinate> = [] {
        willSet {
            objectWillChange.send()
        }
    }
}

extension ToothObject {
    static func create(number: Int) -> ToothObject {
        var outerFurc: [FurcationClass] = []
        var innerFurc: [FurcationClass] = []
        
        switch number {
        // Maxillary molars
        case 16, 17, 18, 26, 27, 28:
            outerFurc = [.zero]
            innerFurc = [.zero, .zero]
        // Maxillary first premolars
        case 14, 24:
            outerFurc = []
            innerFurc = [.zero, .zero]
        // Mandibular molars
        case 46, 47, 48, 36, 37, 38:
            outerFurc = [.zero]
            innerFurc = [.zero]
        default:
            break
        }
        
        let furcData: FurcationData? = (outerFurc.isEmpty && innerFurc.isEmpty) ? nil : FurcationData(outer: outerFurc, inner: innerFurc)
        
        return ToothObject(
            toothNumber: number,
            probingDepth: AspectData(outer: [0,0,0], inner: [0,0,0]),
            gingivalMargin: AspectData(outer: [0,0,0], inner: [0,0,0]),
            mobility: .zero,
            furcation: furcData,
            bleeding: AspectData(outer: [false,false,false], inner: [false,false,false]),
            plaque: AspectData(outer: [false,false,false], inner: [false,false,false]),
            missing: false,
            implant: false
        )
    }

    static func mock(number: Int) -> ToothObject {
        var tooth = create(number: number)
        tooth.probingDepth = AspectData(outer: [3, 5, 2], inner: [3, 5, 2])
        tooth.gingivalMargin = AspectData(outer: [0, -2, 1], inner: [0, -2, 1])
        tooth.bleeding = AspectData(outer: [false, true, false], inner: [false, true, false])
        return tooth
    }
    
    static func fullMouthMock() -> [Int: ToothObject] {
        var mouth: [Int: ToothObject] = [:]
        let allTeeth = [
            18,17,16,15,14,13,12,11,
            21,22,23,24,25,26,27,28,
            48,47,46,45,44,43,42,41,
            31,32,33,34,35,36,37,38
        ]
        for t in allTeeth {
            mouth[t] = ToothObject.mock(number: t)
        }
        return mouth
    }
    
    static func fullMouthEmpty() -> [Int: ToothObject] {
        var mouth: [Int: ToothObject] = [:]
        let allTeeth = [
            18,17,16,15,14,13,12,11,
            21,22,23,24,25,26,27,28,
            48,47,46,45,44,43,42,41,
            31,32,33,34,35,36,37,38
        ]
        for t in allTeeth {
            mouth[t] = ToothObject.create(number: t)
        }
        return mouth
    }
}

