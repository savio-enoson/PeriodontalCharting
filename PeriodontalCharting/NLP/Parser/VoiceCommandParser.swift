import Foundation

class VoiceCommandParser {
    var cursor: ChartingCursor
    var activeSelection: TeethSelection?
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
