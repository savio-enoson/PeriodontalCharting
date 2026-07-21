import Foundation

struct ChartingCursor: Equatable {
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
        return true
    }
    
    mutating func jumpTo(tooth: Int) {
        self.currentTooth = tooth
    }
    
    mutating func syncWithSequence() {
        if sequenceIndex < currentSequence.count {
            self.currentTooth = currentSequence[sequenceIndex]
        }
        
        if configuration.primaryOrder == .jawFirst {
            let jaw = configuration.jawOrder[primaryIndex]
            let aspectOrder = jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder
            guard secondaryIndex < aspectOrder.count else { return }
            let aspect = aspectOrder[secondaryIndex]
            self.currentAspect = (aspect == .buccal) ? .outer : .inner
        } else {
            guard primaryIndex < configuration.aspectOrder.count else { return }
            let aspect = configuration.aspectOrder[primaryIndex]
            self.currentAspect = (aspect == .buccal) ? .outer : .inner
        }
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
