import SwiftUI

// MARK: - ImplantCheckCell

struct ImplantCheckCell: View {
    let isChecked: Bool
    let isSelected: Bool
    let isMissing: Bool

    var body: some View {
        ZStack {
            if isMissing {
                HatchedPattern()
            } else {
                Color(.systemBackground)
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundStyle(isChecked ? Color.blue : Color(.separator))
            }
            if isSelected {
                Rectangle().strokeBorder(Color.orange, lineWidth: 2)
            }
        }
        .frame(height: 18)
    }
}

// MARK: - SingleValueCell

struct SingleValueCell: View {
    let value: String
    let isSelected: Bool
    let isMissing: Bool

    var body: some View {
        ZStack {
            if isMissing {
                HatchedPattern()
            } else {
                Color(.systemBackground)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isSelected {
                Rectangle().strokeBorder(Color.orange, lineWidth: 2)
            }
        }
        .frame(height: 18)
    }
}

// MARK: - FurcationCell

struct FurcationCell: View {
    let furcation: [FurcationClass]?
    let selectedSites: [Bool]
    let isMissing: Bool

    var body: some View {
        if let values = furcation, !values.isEmpty {
            HStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { i in
                    ZStack {
                        if isMissing {
                            HatchedPattern()
                        } else {
                            Color(.systemBackground)
                            Text("\(values[i].rawValue)")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        
                        if i < selectedSites.count && selectedSites[i] {
                            Rectangle().strokeBorder(Color.orange, lineWidth: 2)
                        }

                        if i < values.count - 1 {
                            HStack {
                                Spacer()
                                Color(.separator).frame(width: 1)
                            }
                        }
                    }
                }
            }
            .frame(height: 18)
        } else {
            if isMissing {
                HatchedPattern()
                    .frame(height: 18)
            } else {
                Color(.systemBackground)
                    .frame(height: 18)
            }
        }
    }
}

// MARK: - TripleValueRow

struct TripleValueRow: View {
    let values: [Int]
    let selectedSites: [Bool]
    let isMissing: Bool
    var isProbingDepth: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                ZStack {
                    if isMissing {
                        HatchedPattern()
                    } else {
                        Color(.systemBackground)
                        if i < values.count {
                            Text("\(values[i])")
                                .font(.caption)
                                .foregroundStyle(isProbingDepth && values[i] >= 4 ? .red : .primary)
                        }
                    }
                    if i < selectedSites.count && selectedSites[i] {
                        Rectangle().strokeBorder(Color.orange, lineWidth: 2)
                    }
                }
            }
        }
        .frame(height: 18)
    }
}

// MARK: - BoolDotRow

struct BoolDotRow: View {
    let values: [Bool]
    let dotColor: Color
    let selectedSites: [Bool]
    let isMissing: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                ZStack {
                    if isMissing {
                        HatchedPattern()
                    } else {
                        Color(.systemBackground)
                        if i < values.count && values[i] {
                            Circle()
                                .fill(dotColor)
                                .frame(width: 6, height: 6)
                        } else {
                            Circle()
                                .stroke(Color(.separator), lineWidth: 1)
                                .frame(width: 6, height: 6)
                        }
                    }
                    
                    if i < selectedSites.count && selectedSites[i] {
                        Rectangle().strokeBorder(Color.orange, lineWidth: 2)
                    }
                }
            }
        }
        .frame(height: 18)
    }
}

// MARK: - HatchedPattern

struct HatchedPattern: View {
    var body: some View {
        ZStack {
            Color(.tertiarySystemBackground).opacity(0.5)
            GeometryReader { geo in
                Path { path in
                    let step: CGFloat = 6
                    let maxDim = max(geo.size.width, geo.size.height) * 2
                    for i in stride(from: -maxDim, to: maxDim, by: step) {
                        path.move(to: CGPoint(x: i, y: 0))
                        path.addLine(to: CGPoint(x: i + geo.size.height, y: geo.size.height))
                    }
                }
                .stroke(Color(.separator).opacity(0.6), lineWidth: 1)
            }
            .clipped()
        }
    }
}

