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

struct ChartingConfiguration: Codable, Equatable {
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
    // Default follows a continuous zig-zag pattern around the mouth
    var directionMapping: [String: AnnotationDirection] = [
        "Upper-Buccal": .leftToRight,
        "Upper-Palatal": .rightToLeft,
        "Lower-Buccal": .rightToLeft,
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

