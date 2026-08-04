import Foundation

struct ChartTestingUtilities {
    
    static func getProjectDirectoryURL() -> URL {
        return URL(fileURLWithPath: "/Users/vio/PycharmProjects/Periodontology/PeriodontalCharting/PeriodontalCharting/TestTranscripts/")
    }
    
    static func getFileURL() -> URL {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst) || os(macOS)
        return getProjectDirectoryURL().appendingPathComponent("ground_truth.json")
        #else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ground_truth.json")
        #endif
    }
    
    static func saveChart(mouth: [Int: ToothObject]) -> Bool {
        let url = getFileURL()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            // Save as an array to avoid dictionary key encoding edge cases
            let array = Array(mouth.values).sorted(by: { $0.toothNumber < $1.toothNumber })
            let data = try encoder.encode(array)
            try data.write(to: url)
            print("Successfully saved ground truth to \(url.path)")
            return true
        } catch {
            print("Failed to save ground truth: \(error)")
            return false
        }
    }
    
    static func loadChart() -> [Int: ToothObject]? {
        let url = getFileURL()
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let array = try decoder.decode([ToothObject].self, from: data)
            var mouth: [Int: ToothObject] = [:]
            for tooth in array {
                mouth[tooth.toothNumber] = tooth
            }
            return mouth
        } catch {
            print("Failed to load ground truth: \(error)")
            return nil
        }
    }
    
    static func compareCharts(expected: [Int: ToothObject], actual: [Int: ToothObject]) -> [String] {
        var differences: [String] = []
        for (toothNum, expectedTooth) in expected {
            guard let actualTooth = actual[toothNum] else {
                differences.append("Missing tooth \(toothNum) in actual chart")
                continue
            }
            if expectedTooth.missing != actualTooth.missing {
                differences.append("Tooth \(toothNum) Missing status mismatch.")
                continue // If they mismatch on missing status, further detailed comparison is often noisy.
            }
            
            if expectedTooth.missing {
                continue // If both are missing, we don't care about the other values.
            }
            
            if expectedTooth.probingDepth != actualTooth.probingDepth {
                differences.append("Tooth \(toothNum) PD mismatch. Expected: \(expectedTooth.probingDepth), Actual: \(actualTooth.probingDepth)")
            }
            if expectedTooth.gingivalMargin != actualTooth.gingivalMargin {
                differences.append("Tooth \(toothNum) GM mismatch. Expected: \(expectedTooth.gingivalMargin), Actual: \(actualTooth.gingivalMargin)")
            }
            if expectedTooth.bleeding != actualTooth.bleeding {
                differences.append("Tooth \(toothNum) Bleeding mismatch.")
            }
            if expectedTooth.plaque != actualTooth.plaque {
                differences.append("Tooth \(toothNum) Plaque mismatch.")
            }
            if expectedTooth.mobility != actualTooth.mobility {
                differences.append("Tooth \(toothNum) Mobility mismatch. Expected: \(expectedTooth.mobility), Actual: \(actualTooth.mobility)")
            }
            if expectedTooth.furcation != actualTooth.furcation {
                differences.append("Tooth \(toothNum) Furcation mismatch. Expected: \(String(describing: expectedTooth.furcation)), Actual: \(String(describing: actualTooth.furcation))")
            }
            if expectedTooth.implant != actualTooth.implant {
                differences.append("Tooth \(toothNum) Implant mismatch. Expected: \(expectedTooth.implant), Actual: \(actualTooth.implant)")
            }
        }
        return differences
    }
    
    @MainActor
    static func parseTranscript(text: String, config: ChartingConfiguration) -> [Int: ToothObject] {
        var mouth = ToothObject.fullMouthEmpty()
        let parser = VoiceCommandParser(configuration: config)
        let commands = parser.parse(text: text, isFinal: true)
        
        for command in commands {
            ChartProcessor.apply(command: command, to: &mouth)
        }
        
        return mouth
    }
}
