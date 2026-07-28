import SwiftUI

// MARK: - ToothColumnView

struct ToothColumnView: View {
    var teeth: [ToothObject]
    var index: Int
    var isUpperJaw: Bool

    @EnvironmentObject var selectionModel: ChartSelectionModel

    private var tooth: ToothObject { teeth[index] }

    // MARK: - Selection Helpers

    private func isCellSelected(op: AnnotationOperation) -> Bool {
        let coord = ChartCellCoordinate(toothNumber: tooth.toothNumber, operation: op, aspect: nil, siteIndex: nil)
        return selectionModel.selectedCells.contains(coord)
    }

    private func isSiteSelected(op: AnnotationOperation, isOuter: Bool, site: Int) -> Bool {
        let aspect: ChartAspect = isOuter ? .outer : .inner
        let coord = ChartCellCoordinate(toothNumber: tooth.toothNumber, operation: op, aspect: aspect, siteIndex: site)
        return selectionModel.selectedCells.contains(coord)
    }
    
    private func selectedSites(for op: AnnotationOperation, isOuter: Bool) -> [Bool] {
        return (0..<3).map { isSiteSelected(op: op, isOuter: isOuter, site: $0) }
    }

    // MARK: - Ghosting Helpers (tentative preview values, see ChartSelectionModel)

    private func isCellGhosted(op: AnnotationOperation) -> Bool {
        let coord = ChartCellCoordinate(toothNumber: tooth.toothNumber, operation: op, aspect: nil, siteIndex: nil)
        return selectionModel.ghostedCells.contains(coord)
    }

    private func isSiteGhosted(op: AnnotationOperation, isOuter: Bool, site: Int) -> Bool {
        let aspect: ChartAspect = isOuter ? .outer : .inner
        let coord = ChartCellCoordinate(toothNumber: tooth.toothNumber, operation: op, aspect: aspect, siteIndex: site)
        return selectionModel.ghostedCells.contains(coord)
    }

    private func ghostedSites(for op: AnnotationOperation, isOuter: Bool) -> [Bool] {
        return (0..<3).map { isSiteGhosted(op: op, isOuter: isOuter, site: $0) }
    }

    /// CAL is computed from probing depth − gingival margin, so a CAL cell is
    /// tentative whenever either of its inputs is.
    private func calGhostedSites(isOuter: Bool) -> [Bool] {
        let pd = ghostedSites(for: .probingDepth, isOuter: isOuter)
        let gm = ghostedSites(for: .gingivalMargin, isOuter: isOuter)
        return (0..<3).map { pd[$0] || gm[$0] }
    }

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 4) {
                Text("\(tooth.toothNumber)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(height: 24)

                VStack(spacing: 6) {
                    sharedGrid()
                    aspectGrid(isOuter: isUpperJaw ? true : false)
                }
            }
            .overlay(alignment: .trailing) {
                if index < teeth.count - 1 {
                    Color(.separator).frame(width: 1)
                }
            }

            toothGraphic()

            aspectGrid(isOuter: isUpperJaw ? false : true)
                .overlay(alignment: .trailing) {
                    if index < teeth.count - 1 {
                        Color(.separator).frame(width: 1)
                    }
                }
        }
        .frame(width: 72)
    }

    // MARK: Tooth Graphic

    @ViewBuilder
    private func toothGraphic() -> some View {
        VStack(spacing: 2) {
            if isUpperJaw {
                ToothGraphicSideView(teeth: teeth, index: index, isOuter: true,  isMirrored: false)
                ToothGraphicSideView(teeth: teeth, index: index, isOuter: false, isMirrored: true)
            } else {
                ToothGraphicSideView(teeth: teeth, index: index, isOuter: false, isMirrored: false)
                ToothGraphicSideView(teeth: teeth, index: index, isOuter: true,  isMirrored: true)
            }
        }
        .overlay {
            if tooth.implant {
                Text("I")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Aspect Grid

    @ViewBuilder
    private func sharedGrid() -> some View {
        VStack(spacing: 1) {
            ImplantCheckCell(isChecked: tooth.implant, isSelected: isCellSelected(op: .implant), isMissing: tooth.missing, isGhosted: isCellGhosted(op: .implant))
            SingleValueCell(value: "\(tooth.mobility.rawValue)", isSelected: isCellSelected(op: .mobility), isMissing: tooth.missing, isGhosted: isCellGhosted(op: .mobility))
        }
        .background(Color(.separator))
    }

    @ViewBuilder
    private func aspectGrid(isOuter: Bool) -> some View {
        VStack(spacing: 1) {
            FurcationCell(
                furcation: isOuter ? tooth.furcation?.outer : tooth.furcation?.inner,
                selectedSites: selectedSites(for: .furcation, isOuter: isOuter),
                isMissing: tooth.missing,
                ghostedSites: ghostedSites(for: .furcation, isOuter: isOuter)
            )
            TripleValueRow(
                values: isOuter ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner,
                selectedSites: selectedSites(for: .gingivalMargin, isOuter: isOuter),
                isMissing: tooth.missing,
                ghostedSites: ghostedSites(for: .gingivalMargin, isOuter: isOuter)
            )
            TripleValueRow(
                values: isOuter ? tooth.probingDepth.outer  : tooth.probingDepth.inner,
                selectedSites: selectedSites(for: .probingDepth, isOuter: isOuter),
                isMissing: tooth.missing,
                isProbingDepth: true,
                ghostedSites: ghostedSites(for: .probingDepth, isOuter: isOuter)
            )
            TripleValueRow(
                values: isOuter ? tooth.attachmentLevel.outer : tooth.attachmentLevel.inner,
                selectedSites: [false, false, false], // CAL is computed, usually not selected directly
                isMissing: tooth.missing,
                ghostedSites: calGhostedSites(isOuter: isOuter)
            )
            BoolDotRow(
                values: isOuter ? tooth.bleeding.outer : tooth.bleeding.inner,
                dotColor: .red,
                selectedSites: selectedSites(for: .bleeding, isOuter: isOuter),
                isMissing: tooth.missing,
                ghostedSites: ghostedSites(for: .bleeding, isOuter: isOuter)
            )
            BoolDotRow(
                values: isOuter ? tooth.plaque.outer   : tooth.plaque.inner,
                dotColor: .blue,
                selectedSites: selectedSites(for: .plaque, isOuter: isOuter),
                isMissing: tooth.missing,
                ghostedSites: ghostedSites(for: .plaque, isOuter: isOuter)
            )
        }
        // 1pt grid background — VStack(spacing:1) gaps reveal this Color as hairlines
        .background(Color(.separator))
    }
}

