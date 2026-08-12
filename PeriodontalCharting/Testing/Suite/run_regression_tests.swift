#if REGRESSION_TEST
import Foundation

@main
struct RegressionRunner {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count < 3 {
            print("Usage: run_regression_tests <transcript.txt> <ground_truth.json> [--save]")
            return
        }
        
        let transcriptPath = args[1] 
        let groundTruthPath = args[2]
        let saveMode = args.count > 3 && args[3] == "--save"
        
        UserDefaults.standard.set(false, forKey: "useMLTokenizer")
        
        // 1. Read the transcript
        let transcriptRaw = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        
        print("--- Testing Transcript: \(transcriptPath.components(separatedBy: "/").last ?? "") ---")
        
        // 2. Stream sentences to the parser
        var parser = StatefulParser(configuration: ChartingConfiguration())
        var mouth = ToothObject.fullMouthEmpty()
        
        let lines = transcriptRaw.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let chunk = line.trimmingCharacters(in: .whitespaces)
            if chunk.isEmpty { continue }
            
            let isFinal = (i == lines.count - 1)
            var tokens = TokenizerManager.shared.tokenize(text: chunk, isFinal: isFinal, currentMetric: parser.cursor.currentMetric)
            tokens.append(.word("_sep_"))
            print("Tokens: \(tokens)")
            parser.consume(tokens: tokens, isFinal: isFinal)
            print("Aspect is now: \(parser.cursor.currentAspect)")
        }
        
        // Force a final flush just in case the last line was empty
        parser.consume(tokens: [], isFinal: true)
        
        let commands = parser.commands
        for command in commands {
            ChartProcessor.apply(command: command, to: &mouth)
        }
        
        if saveMode {
            // Save the actual output as the new ground truth
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let array = Array(mouth.values).sorted(by: { $0.toothNumber < $1.toothNumber })
            let data = try encoder.encode(array)
            try data.write(to: URL(fileURLWithPath: groundTruthPath))
            print("✅ SAVED: New ground truth written to \(groundTruthPath)")
        } else {
            // 3. Read the ground truth JSON
            let gtData = try Data(contentsOf: URL(fileURLWithPath: groundTruthPath))
            let decoder = JSONDecoder()
            let gtArray = try decoder.decode([ToothObject].self, from: gtData)
            var expectedMouth: [Int: ToothObject] = [:]
            for t in gtArray { expectedMouth[t.toothNumber] = t }
            
            // 4. Compare
            let diffs = ChartTestingUtilities.compareCharts(expected: expectedMouth, actual: mouth)
            if diffs.isEmpty {
                print("✅ PASSED: No differences found!")
            } else {
                print("❌ FAILED: Differences found:")
                for d in diffs {
                    print("  - \(d)")
                }
            }
        }
        print("--------------------------------------------------\n")
    }
}
#endif
