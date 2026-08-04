import Foundation

extension VoiceCommandParser {
    func isImplicitToothIdentifier(at index: Int, in tokens: [VoiceToken]) -> Bool {
        guard index + 1 < tokens.count, case .number(let n) = tokens[index] else { return false }
        
        var nextNumIdx = index + 1
        while nextNumIdx < tokens.count, case .word(let w) = tokens[nextNumIdx], w == "_sep_" {
            nextNumIdx += 1
        }
        
        guard nextNumIdx < tokens.count, case .number(let nextNum) = tokens[nextNumIdx] else { return false }
        
        let combined = n * 10 + nextNum
        let jaw = combined / 10
        let pos = combined % 10
        if jaw >= 1 && jaw <= 4 && pos >= 1 && pos <= 8 {
            var thirdNumIdx = nextNumIdx + 1
            while thirdNumIdx < tokens.count, case .word(let w) = tokens[thirdNumIdx], w == "_sep_" {
                thirdNumIdx += 1
            }
            if thirdNumIdx < tokens.count, case .number(_) = tokens[thirdNumIdx] {
                return false
            }
            return true
        }
        return false
    }

    func hasUpcomingToothIdentifier(from index: Int, in tokens: [VoiceToken]) -> Bool {
        var j = index + 1
        while j < tokens.count {
            if isImplicitToothIdentifier(at: j, in: tokens) { return true }
            switch tokens[j] {
            case .toothIdentifier(_):
                return true
            case .metric(_, _), .action(_), .number(_):
                return false
            case .word(let w):
                if w == "_sep_" { return false }
                j += 1
            default:
                j += 1
            }
        }
        return false
    }
    
    func resolveAnatomyWithLookahead(anatomy: AnatomyType, for tooth: Int, toothIndex: Int, tokens: [VoiceToken]) -> (aspect: ChartAspect, site: Int?)? {
        guard var resolved = ChartAnatomyResolver.resolve(anatomy: anatomy, for: tooth, currentAspect: cursor.currentAspect) else { return nil }
        let isFullAspectTarget = (anatomy == .buccal || anatomy == .labial || anatomy == .lingual || anatomy == .palatal)
        if isFullAspectTarget {
            var numCount = 0
            var simulatedCount = 0
            var j = toothIndex + 1
            lookaheadLoop: while j < tokens.count {
                if simulatedCount == 0, isImplicitToothIdentifier(at: j, in: tokens) { break lookaheadLoop }
                let t = tokens[j]
                switch t {
                case .number(_):
                    numCount += 1
                    simulatedCount += 1
                case .anatomy(_), .metric(_, _), .toothIdentifier(_), .action(_):
                    break lookaheadLoop
                case .word(_):
                    break
                }
                j += 1
            }
            if numCount < 3 {
                resolved.site = 1
            }
        }
        guard let aspect = resolved.aspect else { return nil }
        return (aspect, resolved.site)
    }
    
    func isContinuingList(after index: Int, in tokens: [VoiceToken]) -> Bool {
        var peek = index + 1
        while peek < tokens.count {
            switch tokens[peek] {
            case .action(_), .metric(_, _):
                return false
            case .word(let w) where w == "_sep_" || w == "dan" || w == "serta" || w == "juga":
                peek += 1
            case .anatomy(_):
                peek += 1
            case .toothIdentifier(_):
                return true
            case .word(_):
                peek += 1
            default:
                return false
            }
        }
        return false
    }
}
