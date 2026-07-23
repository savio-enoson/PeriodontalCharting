import Foundation

@main
struct Runner {
    static func main() async {
        print("Starting Regression Test from Terminal...")

        guard let transcript = TestTranscripts.all.first(where: { $0.0 == "dr_lucky_ground" })?.1 else {
            print("Error: Could not find transcript.")
            exit(1)
        }

        let config = ChartingConfiguration()
        let groundTruthURL = ChartTestingUtilities.getFileURL()

        guard let expectedMouth = ChartTestingUtilities.loadChart() else {
            print("Error: Could not load ground_truth.json from \(groundTruthURL.path).")
            print("Make sure to save it first using the app's Debug Menu.")
            exit(1)
        }

        print("Loaded ground truth successfully.")
        print("Parsing transcript 'dr_lucky_ground'...")

        let actualMouth = await ChartTestingUtilities.parseTranscript(text: transcript, config: config)

        let diffs = ChartTestingUtilities.compareCharts(expected: expectedMouth, actual: actualMouth)

        if diffs.isEmpty {
            print("✅ Regression Test PASSED: No differences found.")
            exit(0)
        } else {
            print("❌ Regression Test FAILED:")
            for diff in diffs {
                print("  - \(diff)")
            }
            exit(1)
        }
    }
}
