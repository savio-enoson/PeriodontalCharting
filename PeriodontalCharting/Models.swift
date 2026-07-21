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

struct FurcationData {
    var outer: [FurcationClass]
    var inner: [FurcationClass]
}

struct AspectData<T> {
    var outer: [T]
    var inner: [T]
}

struct ToothObject: Identifiable {
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

struct TeethSelection {
    var startTooth: ToothObject
    var startIndex: Int
    var endTooth: ToothObject
    var endIndex: Int
    
    var selectedTeeth: [ToothObject] {
        return []
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
}

struct AnnotationCommand {
    var operation: AnnotationOperation
    var teethSelection: TeethSelection
    var values: [Int]
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
}

// MARK: - Voice Parsing

enum ActionType: String, Equatable {
    case next = "lanjut"
    case missing = "gak"
    case missing2 = "tidak"
    case from = "dari"
    case until = "sampai"
    case until2 = "hingga"
    case minus = "minus"
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
        let cleaned = text.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
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
    
    init(configuration: ChartingConfiguration) {
        self.cursor = ChartingCursor(configuration: configuration)
    }
    
    func parse(text: String) -> [AnnotationCommand] {
        let tokens = VoiceTokenizer.tokenize(text: text)
        var commands: [AnnotationCommand] = []
        var i = 0
        
        var currentNumbers: [Int] = []
        
        func flushNumbers() {
            if currentNumbers.isEmpty { return }
            
            var temp = currentNumbers
            while temp.count > 0 {
                let chunk = Array(temp.prefix(3))
                temp = Array(temp.dropFirst(3))
                
                var values = chunk
                if values.count < 3 {
                    let fill = values.last ?? 0
                    while values.count < 3 { values.append(fill) }
                }
                
                let cmd = AnnotationCommand(
                    operation: cursor.currentMetric,
                    teethSelection: TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startIndex: 0, endTooth: ToothObject.create(number: cursor.currentTooth), endIndex: 0),
                    values: values
                )
                commands.append(cmd)
                _ = cursor.advanceToNextTooth()
            }
            currentNumbers = []
        }
        
        while i < tokens.count {
            let token = tokens[i]
            
            switch token {
            case .number(let n):
                currentNumbers.append(n)
                i += 1
                
            case .toothIdentifier(let t):
                flushNumbers()
                cursor.jumpTo(tooth: t)
                i += 1
                
            case .metric(let m):
                flushNumbers()
                cursor.setMetric(m)
                i += 1
                
            case .action(let a):
                if a == .next {
                    flushNumbers()
                    _ = cursor.advanceToNextRow()
                } else if a == .missing || a == .missing2 {
                    flushNumbers()
                    let cmd = AnnotationCommand(
                        operation: .missing,
                        teethSelection: TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startIndex: 0, endTooth: ToothObject.create(number: cursor.currentTooth), endIndex: 0),
                        values: []
                    )
                    commands.append(cmd)
                    _ = cursor.advanceToNextTooth()
                }
                i += 1
                
            case .anatomy(let a):
                if a == .lowerJaw {
                    flushNumbers()
                    _ = cursor.jumpTo(jaw: .lower)
                } else if a == .palatal || a == .lingual {
                    flushNumbers()
                    _ = cursor.jumpTo(aspect: .palatal)
                } else if a == .buccal || a == .labial {
                    flushNumbers()
                    _ = cursor.jumpTo(aspect: .buccal)
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
        
        flushNumbers()
        return commands
    }
}
