import Foundation

enum PrimaryOrderType: String, CaseIterable, Identifiable, Codable {
    case jawFirst = "Upper Jaw <-> Lower Jaw"
    case aspectFirst = "Outer Side <-> Inner Side"
    var id: String { rawValue }
}

enum JawType: String, CaseIterable, Codable {
    case upper = "Upper"
    case lower = "Lower"
}

enum AspectType: String, CaseIterable, Codable {
    case buccal = "Buccal"
    case palatal = "Palatal"
}

enum AnnotationDirection: String, CaseIterable, Codable {
    case leftToRight = "Left to Right"
    case rightToLeft = "Right to Left"
}

extension AspectType {
    func displayName(for jaw: JawType?) -> String {
        switch self {
        case .buccal:
            return "Buccal / Labial"
        case .palatal:
            if jaw == .upper { return "Palatal" }
            if jaw == .lower { return "Lingual" }
            return "Palatal / Lingual"
        }
    }
}

struct ChartingConfiguration: Codable {
    var primaryOrder: PrimaryOrderType = .jawFirst
    
    // For Jaw First
    var jawOrder: [JawType] = [.upper, .lower]
    var upperAspectOrder: [AspectType] = [.buccal, .palatal]
    var lowerAspectOrder: [AspectType] = [.buccal, .palatal]
    
    // For Aspect First
    var aspectOrder: [AspectType] = [.buccal, .palatal]
    var buccalJawOrder: [JawType] = [.upper, .lower]
    var palatalJawOrder: [JawType] = [.upper, .lower]
    
    // Direction mapping: e.g. "Upper-Buccal" -> .leftToRight
    var directionMapping: [String: AnnotationDirection] = [
        "Upper-Buccal": .leftToRight,
        "Upper-Palatal": .leftToRight,
        "Lower-Buccal": .leftToRight,
        "Lower-Palatal": .leftToRight
    ]
    
    func direction(for jaw: JawType, aspect: AspectType) -> AnnotationDirection {
        return directionMapping["\(jaw.rawValue)-\(aspect.rawValue)"] ?? .leftToRight
    }
    
    mutating func setDirection(_ dir: AnnotationDirection, for jaw: JawType, aspect: AspectType) {
        directionMapping["\(jaw.rawValue)-\(aspect.rawValue)"] = dir
    }
}

extension ChartingConfiguration {
    func getSequence(for jaw: JawType, aspect: AspectType) -> [Int] {
        let dir = direction(for: jaw, aspect: aspect)
        if jaw == .upper {
            return dir == .leftToRight ? 
                [18,17,16,15,14,13,12,11, 21,22,23,24,25,26,27,28] :
                [28,27,26,25,24,23,22,21, 11,12,13,14,15,16,17,18]
        } else {
            return dir == .leftToRight ? 
                [48,47,46,45,44,43,42,41, 31,32,33,34,35,36,37,38] :
                [38,37,36,35,34,33,32,31, 41,42,43,44,45,46,47,48]
        }
    }
}

struct ChartingCursor {
    var currentTooth: Int
    var currentAspect: ChartAspect
    var currentMetric: AnnotationOperation = .probingDepth
    
    var configuration: ChartingConfiguration
    
    // Iteration State
    private(set) var primaryIndex: Int = 0
    private(set) var secondaryIndex: Int = 0
    private(set) var sequenceIndex: Int = 0
    private(set) var currentSequence: [Int] = []
    
    init(configuration: ChartingConfiguration) {
        self.configuration = configuration
        self.currentTooth = 18
        self.currentAspect = .outer
        setupSequence()
    }
    
    private mutating func setupSequence() {
        if configuration.primaryOrder == .jawFirst {
            guard primaryIndex < configuration.jawOrder.count else { return }
            let jaw = configuration.jawOrder[primaryIndex]
            let aspectOrder = jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder
            guard secondaryIndex < aspectOrder.count else { return }
            let aspect = aspectOrder[secondaryIndex]
            
            self.currentSequence = configuration.getSequence(for: jaw, aspect: aspect)
            self.currentAspect = (aspect == .buccal) ? .outer : .inner
            self.sequenceIndex = 0
            if !currentSequence.isEmpty {
                self.currentTooth = currentSequence[0]
            }
        } else {
            guard primaryIndex < configuration.aspectOrder.count else { return }
            let aspect = configuration.aspectOrder[primaryIndex]
            let jawOrder = aspect == .buccal ? configuration.buccalJawOrder : configuration.palatalJawOrder
            guard secondaryIndex < jawOrder.count else { return }
            let jaw = jawOrder[secondaryIndex]
            
            self.currentSequence = configuration.getSequence(for: jaw, aspect: aspect)
            self.currentAspect = (aspect == .buccal) ? .outer : .inner
            self.sequenceIndex = 0
            if !currentSequence.isEmpty {
                self.currentTooth = currentSequence[0]
            }
        }
    }
    
    mutating func advanceToNextTooth() -> Bool {
        sequenceIndex += 1
        if sequenceIndex < currentSequence.count {
            self.currentTooth = currentSequence[sequenceIndex]
            return true
        } else {
            // Reached end of row, advance to next row
            return advanceToNextRow()
        }
    }
    
    mutating func advanceToNextRow() -> Bool {
        secondaryIndex += 1
        var secondaryLimit = 2
        if configuration.primaryOrder == .jawFirst {
            let jaw = configuration.jawOrder[primaryIndex]
            secondaryLimit = (jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder).count
        } else {
            let aspect = configuration.aspectOrder[primaryIndex]
            secondaryLimit = (aspect == .buccal ? configuration.buccalJawOrder : configuration.palatalJawOrder).count
        }
        
        if secondaryIndex >= secondaryLimit {
            primaryIndex += 1
            secondaryIndex = 0
            
            let primaryLimit = configuration.primaryOrder == .jawFirst ? configuration.jawOrder.count : configuration.aspectOrder.count
            if primaryIndex >= primaryLimit {
                return false
            }
        }
        
        setupSequence()
        self.currentMetric = .probingDepth
        return true
    }
    
    mutating func jumpTo(tooth: Int) {
        self.currentTooth = tooth
        self.currentMetric = .probingDepth
    }
    
    mutating func setMetric(_ metric: AnnotationOperation) {
        self.currentMetric = metric
    }
    
    mutating func jumpTo(jaw: JawType) -> Bool {
        if configuration.primaryOrder == .jawFirst {
            if let idx = configuration.jawOrder.firstIndex(of: jaw) {
                primaryIndex = idx
                secondaryIndex = 0
                setupSequence()
                return true
            }
        }
        return false
    }
    
    mutating func jumpTo(aspect: AspectType) -> Bool {
        if configuration.primaryOrder == .jawFirst {
            let jaw = configuration.jawOrder[primaryIndex]
            let order = jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder
            if let idx = order.firstIndex(of: aspect) {
                secondaryIndex = idx
                setupSequence()
                return true
            }
        }
        return false
    }
}
