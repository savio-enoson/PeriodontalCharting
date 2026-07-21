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
        .frame(width: 60)
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
            ImplantCheckCell(isChecked: tooth.implant, isSelected: isCellSelected(op: .implant))
            SingleValueCell(value: "\(tooth.mobility.rawValue)", isSelected: isCellSelected(op: .mobility))
        }
        .background(Color(.separator))
    }

    @ViewBuilder
    private func aspectGrid(isOuter: Bool) -> some View {
        VStack(spacing: 1) {
            FurcationCell(
                furcation: isOuter ? tooth.furcation?.outer : tooth.furcation?.inner,
                selectedSites: selectedSites(for: .furcation, isOuter: isOuter)
            )
            TripleValueRow(
                values: isOuter ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner,
                selectedSites: selectedSites(for: .gingivalMargin, isOuter: isOuter)
            )
            TripleValueRow(
                values: isOuter ? tooth.probingDepth.outer  : tooth.probingDepth.inner,
                selectedSites: selectedSites(for: .probingDepth, isOuter: isOuter)
            )
            TripleValueRow(
                values: isOuter ? tooth.attachmentLevel.outer : tooth.attachmentLevel.inner,
                selectedSites: [false, false, false] // CAL is computed, usually not selected directly
            )
            BoolDotRow(
                values: isOuter ? tooth.bleeding.outer : tooth.bleeding.inner,
                dotColor: .red,
                selectedSites: selectedSites(for: .bleeding, isOuter: isOuter)
            )
            BoolDotRow(
                values: isOuter ? tooth.plaque.outer   : tooth.plaque.inner,
                dotColor: .blue,
                selectedSites: selectedSites(for: .plaque, isOuter: isOuter)
            )
        }
        // 1pt grid background — VStack(spacing:1) gaps reveal this Color as hairlines
        .background(Color(.separator))
    }
}

// MARK: - ImplantCheckCell

private struct ImplantCheckCell: View {
    let isChecked: Bool
    let isSelected: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground)
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(.system(size: 10))
                .foregroundStyle(isChecked ? Color.blue : Color(.separator))
            if isSelected {
                Rectangle().strokeBorder(Color.orange, lineWidth: 2)
            }
        }
        .frame(height: 18)
    }
}

// MARK: - SingleValueCell

private struct SingleValueCell: View {
    let value: String
    let isSelected: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isSelected {
                Rectangle().strokeBorder(Color.orange, lineWidth: 2)
            }
        }
        .frame(height: 18)
    }
}

// MARK: - FurcationCell

private struct FurcationCell: View {
    let furcation: [FurcationClass]?
    let selectedSites: [Bool]

    var body: some View {
        if let values = furcation, !values.isEmpty {
            HStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { i in
                    ZStack {
                        Color(.systemBackground)
                        Text("\(values[i].rawValue)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                        
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
            HatchedPattern()
                .frame(height: 18)
        }
    }
}

// MARK: - TripleValueRow

private struct TripleValueRow: View {
    let values: [Int]
    let selectedSites: [Bool]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                ZStack {
                    Color(.systemBackground)
                    if i < values.count {
                        Text("\(values[i])")
                            .font(.caption)
                            .foregroundStyle(.primary)
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

private struct BoolDotRow: View {
    let values: [Bool]
    let dotColor: Color
    let selectedSites: [Bool]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                ZStack {
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

// MARK: - ToothGraphicSideView

struct ToothGraphicSideView: View {
    var teeth: [ToothObject]
    var index: Int
    var isOuter: Bool
    var isMirrored: Bool

    private var tooth: ToothObject { teeth[index] }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(tooth.missing ? Color(.tertiarySystemBackground) : Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(.separator), lineWidth: 1)
                )

            GeometryReader { geo in
                let rootHeight:  CGFloat = 50.0
                let crownHeight: CGFloat = 30.0
                let lineSpacing          = rootHeight / 10.0
                let w = geo.size.width

                // Reference grid lines (0–10 mm scale)
                Path { path in
                    for i in 0...10 {
                        let y = isMirrored
                            ? crownHeight + CGFloat(i) * lineSpacing
                            : rootHeight  - CGFloat(i) * lineSpacing
                        path.move(to:    CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                .clipShape(RoundedRectangle(cornerRadius: 2))

                // Gingival Margin line (red)
                if let gmPath = createGMPath(w: w, rootHeight: rootHeight, crownHeight: crownHeight, lineSpacing: lineSpacing) {
                    gmPath.stroke(.red, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }

                // Probing Depth line (blue)
                if let pdPath = createPDPath(w: w, rootHeight: rootHeight, crownHeight: crownHeight, lineSpacing: lineSpacing) {
                    pdPath.stroke(.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 80)
    }

    // MARK: Path Builders

    private func createGMPath(w: CGFloat, rootHeight: CGFloat, crownHeight: CGFloat, lineSpacing: CGFloat) -> Path? {
        let pd = isOuter ? tooth.probingDepth.outer : tooth.probingDepth.inner
        let gm = isOuter ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner
        guard !tooth.missing && pd.count == 3 && gm.count == 3 else { return nil }

        let prevTooth = index > 0              ? teeth[index - 1] : nil
        let nextTooth = index < teeth.count-1  ? teeth[index + 1] : nil
        let prevGM    = prevTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }
        let nextGM    = nextTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }

        let gmValues = (0..<3).map { CGFloat(-gm[$0]) }

        var left  = gmValues[0]
        if let pGM = prevGM, pGM.count == 3 { left  = (CGFloat(-pGM[2]) + gmValues[0]) / 2.0 }
        var right = gmValues[2]
        if let nGM = nextGM, nGM.count == 3 { right = (gmValues[2] + CGFloat(-nGM[0])) / 2.0 }

        let xPoints: [CGFloat] = [w * 1/6, w * 3/6, w * 5/6]
        return Path { path in
            let y: (CGFloat) -> CGFloat = { val in
                isMirrored ? crownHeight + val * lineSpacing : rootHeight - val * lineSpacing
            }
            path.move(to:    CGPoint(x: 0,          y: y(left)))
            path.addLine(to: CGPoint(x: xPoints[0], y: y(gmValues[0])))
            path.addLine(to: CGPoint(x: xPoints[1], y: y(gmValues[1])))
            path.addLine(to: CGPoint(x: xPoints[2], y: y(gmValues[2])))
            path.addLine(to: CGPoint(x: w,          y: y(right)))
        }
    }

    private func createPDPath(w: CGFloat, rootHeight: CGFloat, crownHeight: CGFloat, lineSpacing: CGFloat) -> Path? {
        let pd = isOuter ? tooth.probingDepth.outer : tooth.probingDepth.inner
        let gm = isOuter ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner
        guard !tooth.missing && pd.count == 3 && gm.count == 3 else { return nil }

        let prevTooth = index > 0             ? teeth[index - 1] : nil
        let nextTooth = index < teeth.count-1 ? teeth[index + 1] : nil
        let prevGM    = prevTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }
        let nextGM    = nextTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }
        let prevPD    = prevTooth.map { isOuter ? $0.probingDepth.outer   : $0.probingDepth.inner   }
        let nextPD    = nextTooth.map { isOuter ? $0.probingDepth.outer   : $0.probingDepth.inner   }

        let pdValues = (0..<3).map { CGFloat(pd[$0] - gm[$0]) }

        var left  = pdValues[0]
        if let pGM = prevGM, pGM.count == 3, let pPD = prevPD, pPD.count == 3 {
            left = (CGFloat(pPD[2] - pGM[2]) + pdValues[0]) / 2.0
        }
        var right = pdValues[2]
        if let nGM = nextGM, nGM.count == 3, let nPD = nextPD, nPD.count == 3 {
            right = (pdValues[2] + CGFloat(nPD[0] - nGM[0])) / 2.0
        }

        let xPoints: [CGFloat] = [w * 1/6, w * 3/6, w * 5/6]
        return Path { path in
            let y: (CGFloat) -> CGFloat = { val in
                isMirrored ? crownHeight + val * lineSpacing : rootHeight - val * lineSpacing
            }
            path.move(to:    CGPoint(x: 0,          y: y(left)))
            path.addLine(to: CGPoint(x: xPoints[0], y: y(pdValues[0])))
            path.addLine(to: CGPoint(x: xPoints[1], y: y(pdValues[1])))
            path.addLine(to: CGPoint(x: xPoints[2], y: y(pdValues[2])))
            path.addLine(to: CGPoint(x: w,          y: y(right)))
        }
    }
}
