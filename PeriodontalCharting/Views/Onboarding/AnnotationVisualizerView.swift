import SwiftUI

struct AnnotationVisualizerView: View {
    let config: ChartingConfiguration
    
    var body: some View {
        VStack(spacing: 24) {
            ChartSectionVisualizer(jaw: .upper, aspect: .buccal, imageName: "Upper-Outer", label: "Upper Outer", config: config)
            ChartSectionVisualizer(jaw: .upper, aspect: .palatal, imageName: "Upper-Inner", label: "Upper Inner", config: config)
            ChartSectionVisualizer(jaw: .lower, aspect: .palatal, imageName: "Lower-Inner", label: "Lower Inner", config: config)
            ChartSectionVisualizer(jaw: .lower, aspect: .buccal, imageName: "Lower-Outer", label: "Lower Outer", config: config)
        }
        .padding()
    }
}

struct ChartSectionVisualizer: View {
    let jaw: JawType
    let aspect: AspectType
    let imageName: String
    let label: String
    let config: ChartingConfiguration
    
    var body: some View {
        VStack(spacing: 8) {
            visualizerOverlay(for: aspect, label: label)
            
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
        }
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

