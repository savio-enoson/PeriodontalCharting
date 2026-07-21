import SwiftUI
import Combine

enum MobilityClass: Int, CaseIterable {
    case zero = 0
    case one = 1
    case two = 2
    case three = 3
}

enum FurcationClass: Int, CaseIterable {
    case zero = 0
    case one = 1
    case two = 2
    case three = 3
}

struct FurcationData: Equatable {
    var outer: [FurcationClass]
    var inner: [FurcationClass]
}

struct AspectData<T: Equatable>: Equatable {
    var outer: [T]
    var inner: [T]
}

struct ToothObject: Identifiable, Equatable {
    let id = UUID()
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
        if let sa = startAspect, let ss = startSite, let ea = endAspect, let es = endSite {
            return ChartAnatomyResolver.sequence(from: (startTooth.toothNumber, sa, ss), to: (endTooth.toothNumber, ea, es)).count
        }
        return 3
    }
}

struct ChartAnatomyResolver {
    static func resolve(anatomy: AnatomyType, for tooth: Int, currentAspect: ChartAspect) -> (aspect: ChartAspect, site: Int)? {
        let isRight = (11...18).contains(tooth) || (41...48).contains(tooth)
        
        let aspect: ChartAspect
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
    
    static func sequence(from start: (Int, ChartAspect, Int), to end: (Int, ChartAspect, Int)) -> [(Int, ChartAspect, Int)] {
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
        
        guard let startIndex = flat.firstIndex(where: { $0.0 == start.0 && $0.1 == start.1 && $0.2 == start.2 }),
              let endIndex = flat.firstIndex(where: { $0.0 == end.0 && $0.1 == end.1 && $0.2 == end.2 }) else {
            return []
        }
        
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
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

// MARK: - Voice Parsing

enum ActionType: String, Equatable {
    case next = "lanjut"
    case missing = "gak"
    case missing2 = "tidak"
    case from = "dari"
    case until = "sampai"
    case until2 = "hingga"
}

enum AnatomyType: String, Equatable {
    case palatal = "palatal"
    case buccal = "bukal"
    case lingual = "lingual"
    case labial = "labial"
    case mesial = "mesial"
    case distal = "distal"
    case mesioBuccal = "mesio bukal"
    case distoBuccal = "disto bukal"
    case mesioLingual = "mesio lingual"
    case distoLingual = "disto lingual"
    case mesioPalatal = "mesio palatal"
    case distoPalatal = "disto palatal"
    case upperJaw = "rahang atas"
    case lowerJaw = "rahang bawah"
}

enum VoiceToken: Equatable {
    case number(Int)
    case anatomy(AnatomyType)
    case metric(AnnotationOperation)
    case action(ActionType)
    case toothIdentifier(Int)
    case word(String)
}

class VoiceTokenizer {
    static let numberWords: [String: Int] = [
        "nol": 0, "satu": 1, "dua": 2, "tiga": 3, "empat": 4, 
        "lima": 5, "enam": 6, "tujuh": 7, "delapan": 8, "sembilan": 9,
        "sepuluh": 10
    ]
    
    static func tokenize(text: String) -> [VoiceToken] {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "mid-", with: "mid ")
            
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var tokens: [VoiceToken] = []
        
        var i = 0
        while i < words.count {
            let w = words[i]
            let nextW = (i + 1 < words.count) ? words[i+1] : ""
            
            if (w == "gak" || w == "tidak") && nextW == "ada" {
                tokens.append(.action(.missing))
                i += 2; continue
            }
            if w == "mid" {
                if let anatomy = AnatomyType(rawValue: nextW) {
                    tokens.append(.anatomy(anatomy))
                    i += 2; continue
                }
            }
            if w == "mesio" && nextW == "bukal" { tokens.append(.anatomy(.mesioBuccal)); i += 2; continue }
            if w == "disto" && nextW == "bukal" { tokens.append(.anatomy(.distoBuccal)); i += 2; continue }
            if w == "mesio" && (nextW == "lingual" || nextW == "palatal") {
                tokens.append(.anatomy(nextW == "lingual" ? .mesioLingual : .mesioPalatal)); i += 2; continue
            }
            if w == "disto" && (nextW == "lingual" || nextW == "palatal") {
                tokens.append(.anatomy(nextW == "lingual" ? .distoLingual : .distoPalatal)); i += 2; continue
            }
            if w == "rahang" && nextW == "atas" { tokens.append(.anatomy(.upperJaw)); i += 2; continue }
            if w == "rahang" && nextW == "bawah" { tokens.append(.anatomy(.lowerJaw)); i += 2; continue }
            
            if w == "gigi" {
                if let num = Int(nextW) {
                    tokens.append(.toothIdentifier(num))
                    i += 2; continue
                }
            }
            
            if let num = Int(w) {
                if num > 10 && num < 99 {
                    tokens.append(.toothIdentifier(num))
                } else {
                    tokens.append(.number(num))
                }
                i += 1; continue
            }
            if let num = VoiceTokenizer.numberWords[w] {
                tokens.append(.number(num))
                i += 1; continue
            }
            
            if let anatomy = AnatomyType(rawValue: w) { tokens.append(.anatomy(anatomy)); i += 1; continue }
            if w == "lanjut" {
                tokens.append(.action(.next))
                let aspectWords = ["palatal", "lingual", "bukal", "labial"]
                if aspectWords.contains(nextW) {
                    let thirdW = (i + 2 < words.count) ? words[i+2] : ""
                    var skipNext = true
                    if let tNum = Int(thirdW), tNum > 10 && tNum < 99 {
                        skipNext = false
                    }
                    if skipNext {
                        i += 2
                        continue
                    }
                }
                i += 1
                continue
            }
            if let action = ActionType(rawValue: w) { tokens.append(.action(action)); i += 1; continue }
            
            if w == "resesi" { tokens.append(.metric(.gingivalMargin)); i += 1; continue }
            if w == "bop" || w == "berdarah" { tokens.append(.metric(.bleeding)); i += 1; continue }
            if w == "plaque" || w == "plak" { tokens.append(.metric(.plaque)); i += 1; continue }
            
            tokens.append(.word(w))
            i += 1
        }
        return tokens
    }
}

class VoiceCommandParser {
    var cursor: ChartingCursor
    var activeSelection: TeethSelection?
    var pendingValues: [String] = []
    var missingTeeth: Set<Int> = []
    
    init(configuration: ChartingConfiguration) {
        self.cursor = ChartingCursor(configuration: configuration)
    }
    
    func parse(text: String, isFinal: Bool = false) -> [AnnotationCommand] {
        let tokens = VoiceTokenizer.tokenize(text: text)
        var commands: [AnnotationCommand] = []
        var i = 0
        
        var currentNumbers: [Int] = []
        
        func restoreToMainSequence() {
            cursor.setMetric(.probingDepth)
            activeSelection = nil
            cursor.syncWithSequence()
            while missingTeeth.contains(cursor.currentTooth) {
                if !cursor.advanceToNextTooth() { break }
            }
        }
        
        func emitBoolIfPending() {
            let m = cursor.currentMetric
            if m == .bleeding || m == .plaque || m == .implant {
                if let sel = activeSelection {
                    let targetSlots = sel.expectedSlots
                    let values = Array(repeating: "True", count: targetSlots)
                    let cmd = AnnotationCommand(operation: m, teethSelection: sel, aspect: cursor.currentAspect, values: values)
                    commands.append(cmd)
                    activeSelection = nil
                }
            }
        }
        
        func flushNumbers(force: Bool = false) {
            if currentNumbers.isEmpty { return }
            
            let targetSlots = activeSelection?.expectedSlots ?? 3
            
            if currentNumbers.count >= targetSlots || force {
                var values = currentNumbers
                
                if values.count == 1 && targetSlots > 1 {
                    values = Array(repeating: values[0], count: targetSlots)
                } else if values.count < targetSlots {
                    let fill = values.last ?? 0
                    while values.count < targetSlots { values.append(fill) }
                }
                
                values = Array(values.prefix(targetSlots))
                
                let selectionToUse = activeSelection ?? TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil)
                
                if self.activeSelection == nil || self.activeSelection?.expectedSlots == 3 {
                    let jaw: JawType = (11...28).contains(cursor.currentTooth) ? .upper : .lower
                    let aspectType: AspectType = cursor.currentAspect == .outer ? .buccal : .palatal
                    let dir = cursor.configuration.direction(for: jaw, aspect: aspectType)
                    
                    if dir == .rightToLeft {
                        values = values.reversed()
                    }
                }
                
                let cmd = AnnotationCommand(
                    operation: cursor.currentMetric,
                    teethSelection: selectionToUse,
                    aspect: cursor.currentAspect,
                    values: values.map { String($0) }
                )
                commands.append(cmd)
                
                currentNumbers = []
                if self.activeSelection == nil {
                    _ = cursor.advanceToNextTooth()
                    while missingTeeth.contains(cursor.currentTooth) {
                        if !cursor.advanceToNextTooth() { break }
                    }
                }
                self.activeSelection = nil
            }
        }
        
        while i < tokens.count {
            let token = tokens[i]
            
            switch token {
            case .number(let n):
                if cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant {
                    emitBoolIfPending()
                    restoreToMainSequence()
                }
                currentNumbers.append(n)
                flushNumbers(force: false)
                i += 1
                
            case .toothIdentifier(let tooth):
                emitBoolIfPending()
                flushNumbers(force: true)
                
                var isRange = false
                var peek = i + 1
                var endAnatomy: AnatomyType? = nil
                var endTooth: Int? = nil
                
                if peek < tokens.count, case .action(let act) = tokens[peek], (act == .until || act == .until2) {
                    isRange = true
                    peek += 1
                }
                
                if isRange {
                    if peek < tokens.count, case .anatomy(let anat) = tokens[peek] {
                        endAnatomy = anat
                        peek += 1
                    }
                    if peek < tokens.count, case .toothIdentifier(let et) = tokens[peek] {
                        endTooth = et
                        peek += 1
                    }
                }
                
                var startAnatomy: AnatomyType? = nil
                if i > 0, case .anatomy(let anat) = tokens[i-1] {
                    startAnatomy = anat
                }
                
                if let et = endTooth {
                    var sAspect: ChartAspect?
                    var sSite: Int?
                    if let sa = startAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: sa, for: tooth, currentAspect: cursor.currentAspect) {
                        sAspect = resolved.aspect; sSite = resolved.site
                    }
                    var eAspect: ChartAspect?
                    var eSite: Int?
                    if let ea = endAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: et, currentAspect: cursor.currentAspect) {
                        eAspect = resolved.aspect; eSite = resolved.site
                    } else if endAnatomy == nil {
                        eAspect = sAspect; eSite = sSite
                    }
                    self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: sAspect, startSite: sSite, endTooth: ToothObject.create(number: et), endAspect: eAspect, endSite: eSite)
                    i = peek
                } else if isRange {
                    if let sa = startAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: sa, for: tooth, currentAspect: cursor.currentAspect) {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: tooth), endAspect: resolved.aspect, endSite: resolved.site)
                    } else {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: tooth), endAspect: nil, endSite: nil)
                    }
                    i = peek
                } else {
                    if let sa = startAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: sa, for: tooth, currentAspect: cursor.currentAspect) {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: tooth), endAspect: resolved.aspect, endSite: resolved.site)
                    } else {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: tooth), endAspect: nil, endSite: nil)
                    }
                    i += 1
                }
                
            case .metric(let m):
                emitBoolIfPending()
                flushNumbers(force: true)
                self.activeSelection = nil
                cursor.setMetric(m)
                i += 1
                
            case .action(let a):
                if a == .next {
                    if cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant {
                        let sel = activeSelection ?? TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil)
                        let targetSlots = sel.expectedSlots
                        commands.append(AnnotationCommand(operation: cursor.currentMetric, teethSelection: sel, aspect: cursor.currentAspect, values: Array(repeating: "True", count: targetSlots)))
                    }
                    flushNumbers(force: true)
                    restoreToMainSequence()
                } else if a == .missing || a == .missing2 {
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    self.activeSelection = nil
                    
                    self.missingTeeth.insert(cursor.currentTooth)
                    
                    let cmd = AnnotationCommand(
                        operation: .missing,
                        teethSelection: TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil),
                        aspect: cursor.currentAspect,
                        values: ["True"]
                    )
                    commands.append(cmd)
                    _ = cursor.advanceToNextTooth()
                    while missingTeeth.contains(cursor.currentTooth) {
                        if !cursor.advanceToNextTooth() { break }
                    }
                } else if a == .until || a == .until2 {
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    var peek = i + 1
                    var endAnatomy: AnatomyType? = nil
                    var endTooth: Int? = nil
                    
                    if peek < tokens.count, case .anatomy(let anat) = tokens[peek] {
                        endAnatomy = anat
                        peek += 1
                    }
                    if peek < tokens.count, case .toothIdentifier(let et) = tokens[peek] {
                        endTooth = et
                        peek += 1
                    }
                    
                    if let et = endTooth {
                        var eAspect = cursor.currentAspect
                        var eSite: Int? = nil
                        if let ea = endAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: et, currentAspect: cursor.currentAspect) {
                            eAspect = resolved.aspect; eSite = resolved.site
                        }
                        
                        self.activeSelection = TeethSelection(
                            startTooth: ToothObject.create(number: cursor.currentTooth), 
                            startAspect: cursor.currentAspect, 
                            startSite: nil, 
                            endTooth: ToothObject.create(number: et), 
                            endAspect: eAspect, 
                            endSite: eSite
                        )
                        i = peek
                        continue
                    } else {
                        self.activeSelection = nil
                        i = peek
                        continue
                    }
                }
                i += 1
                
            case .anatomy(let a):
                if a == .lowerJaw {
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    self.activeSelection = nil
                    _ = cursor.jumpTo(jaw: .lower)
                } else if a == .upperJaw {
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    self.activeSelection = nil
                    _ = cursor.jumpTo(jaw: .upper)
                } else {
                    if i + 1 < tokens.count, case .toothIdentifier(_) = tokens[i+1] {
                        // Defer selection until the following tooth identifier is processed
                    } else if let resolved = ChartAnatomyResolver.resolve(anatomy: a, for: cursor.currentTooth, currentAspect: cursor.currentAspect) {
                        emitBoolIfPending()
                        flushNumbers(force: true)
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: resolved.aspect, endSite: resolved.site)
                    }
                }
                i += 1
                
            case .word(let w):
                if w == "minus" && i+1 < tokens.count, case .number(let n) = tokens[i+1] {
                    currentNumbers.append(-n)
                    i += 2
                } else {
                    i += 1
                }
            }
        }
        
        if isFinal {
            emitBoolIfPending()
            flushNumbers(force: true)
        }
        
        self.pendingValues = currentNumbers.map { String($0) }
        return commands
    }
}
