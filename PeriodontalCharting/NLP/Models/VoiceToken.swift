import Foundation

enum ActionType: String, Equatable {
    case next = "lanjut"
    case missing = "gak"
    case missing2 = "tidak"
    case from = "dari"
    case until = "sampai"
    case until2 = "hingga"
    // case until3 = "dan"
    case at = "pada"
    case at2 = "di"
    case all = "semua"
    case commit = "selesai"
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
    case midBuccal = "tengah bukal"
    case midLabial = "tengah labial"
    case midLingual = "tengah lingual"
    case midPalatal = "tengah palatal"
    case upperJaw = "rahang atas"
    case lowerJaw = "rahang bawah"
}

enum VoiceToken: Equatable {
    case number(Int)
    case anatomy(AnatomyType)
    case metric(AnnotationOperation, multiplier: Int)
    case action(ActionType)
    case toothIdentifier(Int)
    case word(String)
}
