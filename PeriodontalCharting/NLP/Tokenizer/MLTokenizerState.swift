import Foundation

struct MLTokenizerState {
    var activeMetric: Int
    var priorLabels: [Int]
    var contextWindow: [String]
    var pendingNegative: Bool
    
    init(activeMetric: Int, priorLabels: [Int] = [41, 41, 41], contextWindow: [String] = [], pendingNegative: Bool = false) {
        self.activeMetric = activeMetric
        self.priorLabels = priorLabels
        self.contextWindow = contextWindow
        self.pendingNegative = pendingNegative
    }
}
