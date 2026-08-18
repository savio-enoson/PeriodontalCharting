import Foundation

extension StatefulParser {
    mutating func tryResolveRangeDigits() {
        guard isWaitingForRangeEnd, !pendingRangeDigits.isEmpty else { return }
        
        // Try to form a tooth ID from accumulated digits
        let candidate: Int
        switch pendingRangeDigits.count {
        case 1:
            return  // Single digit — ambiguous, wait for more
        case 2:
            candidate = pendingRangeDigits[0] * 10 + pendingRangeDigits[1]
        default:
            // More than 2 digits — take last two, they're most likely the tooth
            let d = pendingRangeDigits.suffix(2)
            candidate = d[d.startIndex] * 10 + d[d.index(after: d.startIndex)]
        }
        
        guard (11...48).contains(candidate) else { return }  // Not a valid FDI tooth
        
        // Treat as .toothIdentifier(candidate)
        consume(token: .toothIdentifier(candidate))
        pendingRangeDigits = []
    }
    
    mutating func cancelRangeExpectation() {
        if isWaitingForRangeEnd {
            isWaitingForRangeEnd = false
            let digits = pendingRangeDigits
            pendingRangeDigits = []
            for d in digits {
                consume(token: .number(d))
            }
        }
    }
}
