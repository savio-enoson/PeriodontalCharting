import Foundation

@MainActor
func runTests() {
    print("Running tests...")
    let config = ChartingConfiguration()
    for (name, text) in TestTranscripts.all {
        print("Testing \(name)...")
        let mouth = ChartTestingUtilities.parseTranscript(text: text, config: config)
        
        let url = URL(fileURLWithPath: "./PeriodontalCharting/Testing/Ground/ground_truth.json")
        guard let data = try? Data(contentsOf: url) else {
            print("❌ Failed to load ground truth for \(name) (using default ground_truth.json)")
            continue
        }
        guard let array = try? JSONDecoder().decode([ToothObject].self, from: data) else {
            print("❌ Failed to decode ground truth for \(name)")
            continue
        }
        var expectedMouth: [Int: ToothObject] = [:]
        for tooth in array {
            expectedMouth[tooth.toothNumber] = tooth
        }
        
        let diffs = ChartTestingUtilities.compareCharts(expected: expectedMouth, actual: mouth)
        if diffs.isEmpty {
            print("✅ \(name) PASSED")
        } else {
            print("❌ \(name) FAILED with differences:")
            for diff in diffs.prefix(10) {
                print("   - \(diff)")
            }
            if diffs.count > 10 { print("   ... and \(diffs.count - 10) more") }
        }
    }
}

Task {
    await runTests()
    exit(0)
}
RunLoop.main.run()
