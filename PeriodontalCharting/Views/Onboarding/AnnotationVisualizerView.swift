import SwiftUI

struct AnnotationVisualizerView: View {
    let config: ChartingConfiguration
    
    var body: some View {
        VStack(spacing: 24) {
            JawVisualizer(jaw: .upper, config: config)
            JawVisualizer(jaw: .lower, config: config)
        }
        .padding()
    }
}

struct JawVisualizer: View {
    let jaw: JawType
    let config: ChartingConfiguration
    
    var body: some View {
        VStack(spacing: 8) {
            Text("\(jaw.rawValue.capitalized) Jaw")
                .font(.subheadline)
                .fontWeight(.bold)
            
            if jaw == .upper {
                // Upper Jaw: Outer (Top) to Inner (Bottom)
                visualizerOverlay(for: .buccal, label: "Outer Side")
                teethPlaceholder
                visualizerOverlay(for: .palatal, label: "Inner Side")
            } else {
                // Lower Jaw: Inner (Top) to Outer (Bottom)
                visualizerOverlay(for: .palatal, label: "Inner Side")
                teethPlaceholder
                visualizerOverlay(for: .buccal, label: "Outer Side")
            }
        }
    }
    
    private var teethPlaceholder: some View {
        HStack(spacing: 4) {
            ForEach(0..<16, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray4))
                    .frame(height: 32)
            }
        }
        .frame(height: 48)
    }
    
    @ViewBuilder
    private func visualizerOverlay(for aspect: AspectType, label sideText: String) -> some View {
        let index = config.sequenceIndex(for: jaw, aspect: aspect)
        let direction = config.direction(for: jaw, aspect: aspect)
        let isLeftToRight = direction == .leftToRight
        
        VStack(alignment: isLeftToRight ? .leading : .trailing, spacing: 4) {
            Text("\(index). \(sideText)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            HStack(spacing: 0) {
                if isLeftToRight {
                    Image(systemName: "\(index).circle.fill")
                        .foregroundColor(.blue)
                    Rectangle().fill(Color.blue).frame(height: 2)
                    Image(systemName: "arrowtriangle.forward.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 10))
                } else {
                    Image(systemName: "arrowtriangle.backward.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 10))
                    Rectangle().fill(Color.blue).frame(height: 2)
                    Image(systemName: "\(index).circle.fill")
                        .foregroundColor(.blue)
                }
            }
        }
    }
}

extension ChartingConfiguration {
    func sequenceIndex(for jaw: JawType, aspect: AspectType) -> Int {
        var result: [(JawType, AspectType)] = []
        if primaryOrder == .jawFirst {
            for j in jawOrder {
                let aspects = j == .upper ? upperAspectOrder : lowerAspectOrder
                for a in aspects {
                    result.append((j, a))
                }
            }
        } else {
            for a in aspectOrder {
                let jaws = a == .buccal ? buccalJawOrder : palatalJawOrder
                for j in jaws {
                    result.append((j, a))
                }
            }
        }
        
        return (result.firstIndex(where: { $0.0 == jaw && $0.1 == aspect }) ?? 0) + 1
    }
}

