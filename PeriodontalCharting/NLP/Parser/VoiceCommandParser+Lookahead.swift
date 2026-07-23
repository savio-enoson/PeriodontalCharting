import Foundation

extension VoiceCommandParser {
    func hasUpcomingToothIdentifier(from index: Int, in tokens: [VoiceToken]) -> Bool {
        var j = index + 1
        while j < tokens.count {
            switch tokens[j] {
            case .toothIdentifier(_):
                return true
            case .metric(_, _), .action(_), .number(_):
                return false
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
            var j = toothIndex + 1
            lookaheadLoop: while j < tokens.count {
                let t = tokens[j]
                switch t {
                case .number(_):
                    numCount += 1
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
        return (resolved.aspect!, resolved.site)
    }
    
    func isContinuingList(after index: Int, in tokens: [VoiceToken]) -> Bool {
        var peek = index + 1
        while peek < tokens.count {
            switch tokens[peek] {
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
