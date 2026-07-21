import SwiftUI

// MARK: - ToothGraphicSideView

struct ToothGraphicSideView: View {
    var teeth: [ToothObject]
    var index: Int
    var isOuter: Bool
    var isMirrored: Bool

    private var tooth: ToothObject { teeth[index] }

    var body: some View {
        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tooth.missing ? Color(.tertiarySystemBackground) : Color.blue.opacity(0.1))
                
                if tooth.missing {
                    HatchedPattern()
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
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
