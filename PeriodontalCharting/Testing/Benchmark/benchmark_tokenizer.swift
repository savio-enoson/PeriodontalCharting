import Foundation

// MARK: - Models for JSON Parsing
struct BenchmarkRecord: Codable {
    let id: String
    let category: String
    let subcategory: String
    let input_raw: String
    let input_normalized_ml: String
    let input_normalized_legacy: String
    let context: Context
    let ground_truth_tokens: [String]
    let notes: String
}

struct Context: Codable {
    let active_metric: String
    let prior_labels: [String]
}

// MARK: - CSV Output format
struct CSVRow {
    let id: String
    let category: String
    let subcategory: String
    let ml_tokens: String
    let legacy_tokens: String
    let ground_truth_tokens: String
    let ml_correct: Int
    let legacy_correct: Int
    let ml_latency_ms: Double
    let legacy_latency_ms: Double
    let notes: String
    
    func toCSV() -> String {
        let escNotes = notes.replacingOccurrences(of: "\"", with: "\"\"")
        return "\(id),\(category),\(subcategory),\(ml_tokens),\(legacy_tokens),\(ground_truth_tokens),\(ml_correct),\(legacy_correct),\(ml_latency_ms),\(legacy_latency_ms),\"\(escNotes)\""
    }
}

// MARK: - Helpers

// Stub definition to represent token serialization if the actual one from VoiceToken.swift is missing methods.
// We assume VoiceToken has an extension or we write a simple switch to serialize it, but we can't easily do it if VoiceToken is complex.
// Actually, the benchmark plan says:
// "Serializes each tokenizer's output `[VoiceToken]` to the canonical string format from §3.2."
// So I will write an extension for VoiceToken here.

extension VoiceToken {
    func serialize() -> String {
        switch self {
        case .number(let n): return "number:\(n)"
        case .toothIdentifier(let n): return "tooth:\(n)"
        case .metric(let m, let mult):
            let mStr: String
            switch m {
            case .probingDepth: mStr = "probingDepth"
            case .gingivalMargin: mStr = "gingivalMargin"
            case .bleeding: mStr = "bleeding"
            case .plaque: mStr = "plaque"
            case .mobility: mStr = "mobility"
            case .furcation: mStr = "furcation"
            case .implant: mStr = "implant"
            case .missing: mStr = "missing"
            }
            return "metric:\(mStr):\(mult)"
        case .action(let a):
            let aStr: String
            switch a {
            case .commit: aStr = "commit"
            case .missing: aStr = "missing"
            case .missing2: aStr = "missing2"
            case .from: aStr = "from"
            case .until: aStr = "until"
            case .until2: aStr = "until2"
            case .at: aStr = "at"
            case .at2: aStr = "at2"
            case .all: aStr = "all"
            case .next: aStr = "next"
            }
            return "action:\(aStr)"
        case .anatomy(let a):
            let aStr: String
            switch a {
            case .mesioBuccal: aStr = "mesioBuccal"
            case .distoBuccal: aStr = "distoBuccal"
            case .midBuccal: aStr = "midBuccal"
            case .mesioPalatal: aStr = "mesioPalatal"
            case .distoPalatal: aStr = "distoPalatal"
            case .midPalatal: aStr = "midPalatal"
            case .mesioLingual: aStr = "mesioLingual"
            case .distoLingual: aStr = "distoLingual"
            case .midLingual: aStr = "midLingual"
            case .mesioLabial: aStr = "mesioLabial"
            case .distoLabial: aStr = "distoLabial"
            case .midLabial: aStr = "midLabial"
            case .mesial: aStr = "mesial"
            case .distal: aStr = "distal"
            case .buccal: aStr = "buccal"
            case .lingual: aStr = "lingual"
            case .palatal: aStr = "palatal"
            case .labial: aStr = "labial"
            case .upperJaw: aStr = "upperJaw"
            case .lowerJaw: aStr = "lowerJaw"
            }
            return "anatomy:\(aStr)"
        case .word(let w): return "word:\(w)"
        }
    }
}

@main
struct BenchmarkTokenizer {
    static func main() {
        let jsonlPath = "/Users/vio/PycharmProjects/Periodontology/ml/data/benchmark/utterance_token_gt.jsonl"
        let outCSVPath = "/Users/vio/PycharmProjects/Periodontology/ml/data/benchmark/benchmark_results.csv"
        
        guard let data = try? String(contentsOfFile: jsonlPath, encoding: .utf8) else {
            print("Failed to read \(jsonlPath)")
            return
        }
        
        let lines = data.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var records: [BenchmarkRecord] = []
        let decoder = JSONDecoder()
        
        for line in lines {
            if let d = line.data(using: .utf8), let rec = try? decoder.decode(BenchmarkRecord.self, from: d) {
                records.append(rec)
            }
        }
        
        print("Loaded \(records.count) benchmark records.")
        
        let modelURL = URL(fileURLWithPath: "/Users/vio/PycharmProjects/Periodontology/ml/models/Phase1Tokenizer.mlmodelc")
        guard let mlTokenizer = MLVoiceTokenizer(modelURL: modelURL) else {
            print("Failed to initialize MLVoiceTokenizer")
            return
        }
        
        // We will do a warmup loop for both
        print("Warming up MLTokenizer...")
        var dummyState = MLTokenizerState()
        _ = mlTokenizer.tokenize(text: "gigi 16 tiga", isFinal: true, sessionState: &dummyState)
        
        var results: [CSVRow] = []
        
        for (i, record) in records.enumerated() {
            let t0_leg = DispatchTime.now()
            let legacyTokens = VoiceTokenizer.tokenize(text: record.input_normalized_legacy, isFinal: true)
            let t1_leg = DispatchTime.now()
            let legacyLatencyMs = Double(t1_leg.uptimeNanoseconds - t0_leg.uptimeNanoseconds) / 1_000_000
            
            // Setup ML state
            var state = MLTokenizerState()
            state.activeMetric = record.context.active_metric
            state.priorLabels = record.context.prior_labels
            
            let t0_ml = DispatchTime.now()
            let mlTokens = mlTokenizer.tokenize(text: record.input_normalized_ml, isFinal: true, sessionState: &state)
            let t1_ml = DispatchTime.now()
            let mlLatencyMs = Double(t1_ml.uptimeNanoseconds - t0_ml.uptimeNanoseconds) / 1_000_000
            
            let legacyStrTokens = legacyTokens.map { $0.serialize() }
            let mlStrTokens = mlTokens.map { $0.serialize() }
            
            let legacyStr = legacyStrTokens.joined(separator: "|")
            let mlStr = mlStrTokens.joined(separator: "|")
            let gtStr = record.ground_truth_tokens.joined(separator: "|")
            
            let mlCorrect = (mlStrTokens == record.ground_truth_tokens) ? 1 : 0
            let legacyCorrect = (legacyStrTokens == record.ground_truth_tokens) ? 1 : 0
            
            results.append(CSVRow(id: record.id, category: record.category, subcategory: record.subcategory, ml_tokens: mlStr, legacy_tokens: legacyStr, ground_truth_tokens: gtStr, ml_correct: mlCorrect, legacy_correct: legacyCorrect, ml_latency_ms: mlLatencyMs, legacy_latency_ms: legacyLatencyMs, notes: record.notes))
            
            if (i+1) % 50 == 0 {
                print("Processed \(i+1)/\(records.count)")
            }
        }
        
        let csvHeader = "id,category,subcategory,ml_tokens,legacy_tokens,ground_truth_tokens,ml_correct,legacy_correct,ml_latency_ms,legacy_latency_ms,notes\n"
        let csvContent = csvHeader + results.map { $0.toCSV() }.joined(separator: "\n")
        
        try? csvContent.write(toFile: outCSVPath, atomically: true, encoding: .utf8)
        print("L2 Benchmark complete. Results written to \(outCSVPath)")
    }
}
