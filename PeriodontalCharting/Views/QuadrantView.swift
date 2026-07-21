import SwiftUI

struct QuadrantView: View {
    var title: String
    var teeth: [ToothObject]
    var isUpperJaw: Bool
    var showLeftLabels: Bool = true
    var showRightLabels: Bool = true

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(isUpperJaw ? "Outer (Facial)" : "Inner (Lingual)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                if showLeftLabels {
                    SideLabelsView(isUpperJaw: isUpperJaw, alignRight: true)
                        .frame(width: 110)
                    Divider()
                }

                HStack(spacing: 0) {
                    ForEach(Array(teeth.enumerated()), id: \.element.id) { index, _ in
                        ToothColumnView(teeth: teeth, index: index, isUpperJaw: isUpperJaw)
                    }
                }

                if showRightLabels {
                    Divider()
                    SideLabelsView(isUpperJaw: isUpperJaw, alignRight: false)
                        .frame(width: 110)
                }
            }
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color(.separator), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))

            Text(isUpperJaw ? "Inner (Palatal)" : "Outer (Facial)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Side Labels

struct SideLabelsView: View {
    var isUpperJaw: Bool
    var alignRight: Bool

    var body: some View {
        VStack(spacing: 4) {
            Color.clear.frame(height: 24) // Align with tooth number header

            VStack(spacing: 6) {
                sharedGridLabels()
                aspectGridLabels()
            }

            graphicPlaceholder()

            aspectGridLabels()
        }
    }

    @ViewBuilder
    private func graphicPlaceholder() -> some View {
        Color.clear.frame(height: 162)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sharedGridLabels() -> some View {
        VStack(spacing: 1) {
            labelRow("Implant")
            labelRow("Mobility")
        }
    }

    @ViewBuilder
    private func aspectGridLabels() -> some View {
        VStack(spacing: 1) {
            labelRow("Furcation")
            labelRow("Gingival Margin")
            labelRow("Probing Depth")
            labelRow("Attachment Level")
            labelRow("Bleeding")
            labelRow("Plaque")
        }
    }

    @ViewBuilder
    private func labelRow(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(height: 18)
            .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
    }
}
