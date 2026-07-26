import Foundation

class VoiceCommandParser {
    var cursor: ChartingCursor
    var activeSelection: TeethSelection? { didSet { print("ACTIVE SEL CHANGED TO:", activeSelection?.startTooth.toothNumber ?? -1, activeSelection?.startSite ?? -2, "TO", activeSelection?.endTooth.toothNumber ?? -1, activeSelection?.endSite ?? -2) } }
    var pendingValues: [String] = []
    var missingTeeth: Set<Int> = []
    
    var isPostTargeting: Bool = false
    var postTargetTemplate: AnnotationCommand? = nil
    var postTargetAnatomy: AnatomyType? = nil
    
    var metricHadSpecificTargets: Bool = false
    
    // Elevated from parse(text:isFinal:)
    var commands: [AnnotationCommand] = []
    var currentNumbers: [Int] = []
    var currentMetricMultiplier: Int = 1
    var tokens: [VoiceToken] = []
    var tokenIndex: Int = 0
    var lastAutoAdvancedFromTooth: Int? = nil
    
    init(configuration: ChartingConfiguration) {
        self.cursor = ChartingCursor(configuration: configuration)
    }
}
