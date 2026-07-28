import SwiftUI
import UIKit

// MARK: - ToothAssetOffsets
struct ToothAssetOffsets {
    // 0-indexed arrays for each aspect (index 0 = central incisor, index 7 = 3rd molar).
    // Provide exactly 8 values per array.
    // These values are SCREEN POINT offsets added directly to the vertical position of the tooth.
    // Use negative values to move the tooth UP, positive to move it DOWN.
    static let upperBuccal: [CGFloat]  = [23, 13, 7, 11, 4, 1, 1, 5]
    static let upperPalatal: [CGFloat] = [-6, -4, 3, -1, -3, -2, 1, 0]
    static let lowerBuccal: [CGFloat]  = [-14, -10, -7, -7, -6, -8, -12, -11]
    static let lowerLingual: [CGFloat] = [6, 4, -3, 8, 3, -1, -5, -6]
    
    static func offset(for tooth: ToothObject, isOuter: Bool) -> CGFloat {
        let quadrant = tooth.toothNumber / 10
        let id = tooth.toothNumber % 10
        guard id >= 1 && id <= 8 else { return 0 }
        
        let arrayIndex = id - 1
        
        switch quadrant {
        case 1, 2:
            let arr = isOuter ? upperBuccal : upperPalatal
            return arrayIndex < arr.count ? arr[arrayIndex] : 0
        case 3, 4:
            let arr = isOuter ? lowerBuccal : lowerLingual
            return arrayIndex < arr.count ? arr[arrayIndex] : 0
        default:
            return 0
        }
    }
}

// MARK: - ToothGraphicSideView

struct ToothGraphicSideView: View, Equatable {
    var teeth: [ToothObject]
    var index: Int
    var isOuter: Bool
    var isMirrored: Bool
    var targetWidth: CGFloat

    private var tooth: ToothObject { teeth[index] }

    var body: some View {
        let name = imageName(for: tooth, isOuter: isOuter)
        let uiImage = UIImage(named: name)
        
        let originalW = uiImage.map { $0.size.width * $0.scale } ?? 591.0
        let effectiveScale = targetWidth / originalW
        let w = targetWidth
        let h = uiImage.map { ($0.size.height * $0.scale) * effectiveScale } ?? (1173.0 * effectiveScale)
        
        let rootHeight: CGFloat = 150.0 // 240.0 * (50.0 / 80.0)

        return ZStack {
            if !tooth.missing {
                if tooth.implant {
                    VStack(spacing: 0) {
                        if !isMirrored {
                            ZStack(alignment: .bottom) {
                                Rectangle().fill(Color(.systemBackground))
                                Image("implant_screw")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: targetWidth * 0.8)
                            }
                            .frame(height: rootHeight)
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            ZStack(alignment: .top) {
                                Rectangle().fill(Color(.systemBackground))
                                Image("implant_screw")
                                    .resizable()
                                    .scaledToFit()
                                    .scaleEffect(y: -1)
                                    .frame(width: targetWidth * 0.8)
                            }
                            .frame(height: rootHeight)
                        }
                    }
                } else if let img = uiImage {
                    let defaultCEJRatio: CGFloat = isMirrored ? 0.35 : 0.65
                    let defaultCEJ = originalW > 0 ? (img.size.height * img.scale * defaultCEJRatio) : 0
                    
                    let screenOffset = ToothAssetOffsets.offset(for: tooth, isOuter: isOuter)
                    let targetCEJLine: CGFloat = isMirrored ? 90.0 : 150.0
                    let scaledCEJFromTop = defaultCEJ * effectiveScale
                    let centerY = targetCEJLine - scaledCEJFromTop + (h / 2.0) + screenOffset
                    
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: w, height: h)
                        .position(x: targetWidth / 2.0, y: centerY)
                }
            } else {
                VStack(spacing: 0) {
                    if !isMirrored { Spacer(minLength: 0) }
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(.tertiarySystemBackground))
                        HatchedPattern()
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .frame(width: w, height: 240)
                    if isMirrored { Spacer(minLength: 0) }
                }
            }
        }
        .overlay {
            chartLinesOverlay()
        }
        .frame(height: 240)
        .drawingGroup()
    }

    @ViewBuilder
    private func chartLinesOverlay() -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let rootHeight: CGFloat = h * (50.0 / 80.0)
            let crownHeight: CGFloat = h * (30.0 / 80.0)
            
            // The tallest root varies by jaw (Upper ~111.4pt, Lower ~122.0pt).
            // Setting lineSpacing such that the 15th line exactly aligns with the root tip.
            let quadrant = tooth.toothNumber / 10
            let maxRootLength: CGFloat = (quadrant == 1 || quadrant == 2)
                ? (isOuter ? 111.4 : 104.2)
                : (isOuter ? 104.8 : 122.0)
            let lineSpacing = maxRootLength / 15.0
            
            let w = geo.size.width

            // Reference grid lines (0–16 mm scale)
            Path { path in
                for i in 0...16 {
                    let y = isMirrored
                        ? crownHeight + CGFloat(i) * lineSpacing
                        : rootHeight  - CGFloat(i) * lineSpacing
                    path.move(to:    CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
            .clipShape(RoundedRectangle(cornerRadius: 2))

            // Pocket Depth Fill (light blue)
            if let fillPath = createPocketFillPath(w: w, rootHeight: rootHeight, crownHeight: crownHeight, lineSpacing: lineSpacing) {
                fillPath.fill(Color.blue.opacity(0.2))
            }

            // Probing Depth line (blue)
            if let pdPath = createPDPath(w: w, rootHeight: rootHeight, crownHeight: crownHeight, lineSpacing: lineSpacing) {
                pdPath.stroke(.blue, style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round))
            }

            // Gingival Margin line (red)
            if let gmPath = createGMPath(w: w, rootHeight: rootHeight, crownHeight: crownHeight, lineSpacing: lineSpacing) {
                gmPath.stroke(.red, style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round))
            }
        }
    }

    // MARK: Path Builders

    private func createGMPath(w: CGFloat, rootHeight: CGFloat, crownHeight: CGFloat, lineSpacing: CGFloat) -> Path? {
        let pd = isOuter ? tooth.probingDepth.outer : tooth.probingDepth.inner
        let gm = isOuter ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner
        guard !tooth.missing && pd.count == 3 && gm.count == 3 else { return nil }

        let prevTooth = index > 0              ? teeth[index - 1] : nil
        let nextTooth = index < teeth.count-1  ? teeth[index + 1] : nil
        let prevGM    = (prevTooth?.missing == true) ? nil : prevTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }
        let nextGM    = (nextTooth?.missing == true) ? nil : nextTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }

        let gmValues = (0..<3).map { CGFloat(-gm[$0]) }

        var left  = gmValues[0]
        if let pGM = prevGM, pGM.count == 3 { left  = (CGFloat(-pGM[2]) + gmValues[0]) / 2.0 }
        var right = gmValues[2]
        if let nGM = nextGM, nGM.count == 3 { right = (gmValues[2] + CGFloat(-nGM[0])) / 2.0 }

        let x0: CGFloat = (prevTooth?.missing == true || prevTooth == nil) ? 0 : w / 6.0
        let x2: CGFloat = (nextTooth?.missing == true || nextTooth == nil) ? w : 5.0 * w / 6.0

        return Path { path in
            let y: (CGFloat) -> CGFloat = { val in
                isMirrored ? crownHeight + val * lineSpacing : rootHeight - val * lineSpacing
            }
            if x0 > 0 {
                path.move(to: CGPoint(x: 0, y: y(left)))
                path.addLine(to: CGPoint(x: x0, y: y(gmValues[0])))
            } else {
                path.move(to: CGPoint(x: 0, y: y(gmValues[0])))
            }
            
            path.addLine(to: CGPoint(x: w/2, y: y(gmValues[1])))
            path.addLine(to: CGPoint(x: x2, y: y(gmValues[2])))
            
            if x2 < w {
                path.addLine(to: CGPoint(x: w, y: y(right)))
            }
        }
    }

    private func createPDPath(w: CGFloat, rootHeight: CGFloat, crownHeight: CGFloat, lineSpacing: CGFloat) -> Path? {
        let pd = isOuter ? tooth.probingDepth.outer : tooth.probingDepth.inner
        let gm = isOuter ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner
        guard !tooth.missing && pd.count == 3 && gm.count == 3 else { return nil }

        let prevTooth = index > 0             ? teeth[index - 1] : nil
        let nextTooth = index < teeth.count-1 ? teeth[index + 1] : nil
        let prevGM    = (prevTooth?.missing == true) ? nil : prevTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }
        let nextGM    = (nextTooth?.missing == true) ? nil : nextTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }
        let prevPD    = (prevTooth?.missing == true) ? nil : prevTooth.map { isOuter ? $0.probingDepth.outer   : $0.probingDepth.inner   }
        let nextPD    = (nextTooth?.missing == true) ? nil : nextTooth.map { isOuter ? $0.probingDepth.outer   : $0.probingDepth.inner   }

        let pdValues = (0..<3).map { CGFloat(pd[$0] - gm[$0]) }

        var left  = pdValues[0]
        if let pGM = prevGM, pGM.count == 3, let pPD = prevPD, pPD.count == 3 {
            left = (CGFloat(pPD[2] - pGM[2]) + pdValues[0]) / 2.0
        }
        var right = pdValues[2]
        if let nGM = nextGM, nGM.count == 3, let nPD = nextPD, nPD.count == 3 {
            right = (pdValues[2] + CGFloat(nPD[0] - nGM[0])) / 2.0
        }

        let x0: CGFloat = (prevTooth?.missing == true || prevTooth == nil) ? 0 : w / 6.0
        let x2: CGFloat = (nextTooth?.missing == true || nextTooth == nil) ? w : 5.0 * w / 6.0

        return Path { path in
            let y: (CGFloat) -> CGFloat = { val in
                isMirrored ? crownHeight + val * lineSpacing : rootHeight - val * lineSpacing
            }
            if x0 > 0 {
                path.move(to: CGPoint(x: 0, y: y(left)))
                path.addLine(to: CGPoint(x: x0, y: y(pdValues[0])))
            } else {
                path.move(to: CGPoint(x: 0, y: y(pdValues[0])))
            }
            
            path.addLine(to: CGPoint(x: w/2, y: y(pdValues[1])))
            path.addLine(to: CGPoint(x: x2, y: y(pdValues[2])))
            
            if x2 < w {
                path.addLine(to: CGPoint(x: w, y: y(right)))
            }
        }
    }

    private func createPocketFillPath(w: CGFloat, rootHeight: CGFloat, crownHeight: CGFloat, lineSpacing: CGFloat) -> Path? {
        let pd = isOuter ? tooth.probingDepth.outer : tooth.probingDepth.inner
        let gm = isOuter ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner
        guard !tooth.missing && pd.count == 3 && gm.count == 3 else { return nil }

        let prevTooth = index > 0             ? teeth[index - 1] : nil
        let nextTooth = index < teeth.count-1 ? teeth[index + 1] : nil
        let prevGM    = (prevTooth?.missing == true) ? nil : prevTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }
        let nextGM    = (nextTooth?.missing == true) ? nil : nextTooth.map { isOuter ? $0.gingivalMargin.outer : $0.gingivalMargin.inner }
        let prevPD    = (prevTooth?.missing == true) ? nil : prevTooth.map { isOuter ? $0.probingDepth.outer   : $0.probingDepth.inner   }
        let nextPD    = (nextTooth?.missing == true) ? nil : nextTooth.map { isOuter ? $0.probingDepth.outer   : $0.probingDepth.inner   }

        let gmValues = (0..<3).map { CGFloat(-gm[$0]) }
        let pdValues = (0..<3).map { CGFloat(pd[$0] - gm[$0]) }

        var leftGM = gmValues[0]
        var leftPD = pdValues[0]
        if let pGM = prevGM, pGM.count == 3 { leftGM = (CGFloat(-pGM[2]) + gmValues[0]) / 2.0 }
        if let pGM = prevGM, pGM.count == 3, let pPD = prevPD, pPD.count == 3 {
            leftPD = (CGFloat(pPD[2] - pGM[2]) + pdValues[0]) / 2.0
        }

        var rightGM = gmValues[2]
        var rightPD = pdValues[2]
        if let nGM = nextGM, nGM.count == 3 { rightGM = (gmValues[2] + CGFloat(-nGM[0])) / 2.0 }
        if let nGM = nextGM, nGM.count == 3, let nPD = nextPD, nPD.count == 3 {
            rightPD = (pdValues[2] + CGFloat(nPD[0] - nGM[0])) / 2.0
        }

        let x0: CGFloat = (prevTooth?.missing == true || prevTooth == nil) ? 0 : w / 6.0
        let x2: CGFloat = (nextTooth?.missing == true || nextTooth == nil) ? w : 5.0 * w / 6.0

        return Path { path in
            let y: (CGFloat) -> CGFloat = { val in
                isMirrored ? crownHeight + val * lineSpacing : rootHeight - val * lineSpacing
            }
            
            // GM Path (left to right)
            if x0 > 0 {
                path.move(to: CGPoint(x: 0, y: y(leftGM)))
                path.addLine(to: CGPoint(x: x0, y: y(gmValues[0])))
            } else {
                path.move(to: CGPoint(x: 0, y: y(gmValues[0])))
            }
            
            path.addLine(to: CGPoint(x: w/2, y: y(gmValues[1])))
            path.addLine(to: CGPoint(x: x2, y: y(gmValues[2])))
            
            if x2 < w {
                path.addLine(to: CGPoint(x: w, y: y(rightGM)))
                path.addLine(to: CGPoint(x: w, y: y(rightPD)))
            } else {
                path.addLine(to: CGPoint(x: w, y: y(pdValues[2])))
            }
            
            // PD Path (right to left)
            if x2 < w {
                path.addLine(to: CGPoint(x: x2, y: y(pdValues[2])))
            }
            
            path.addLine(to: CGPoint(x: w/2, y: y(pdValues[1])))
            
            if x0 > 0 {
                path.addLine(to: CGPoint(x: x0, y: y(pdValues[0])))
                path.addLine(to: CGPoint(x: 0, y: y(leftPD)))
            } else {
                path.addLine(to: CGPoint(x: 0, y: y(pdValues[0])))
            }
            
            path.closeSubpath()
        }
    }

    private func imageName(for tooth: ToothObject, isOuter: Bool) -> String {
        let quadrant = tooth.toothNumber / 10
        let id = tooth.toothNumber % 10
        let aspect: String
        if isOuter {
            aspect = "B"
        } else {
            aspect = (quadrant == 1 || quadrant == 2) ? "P" : "L"
        }
        return "\(quadrant)-\(id) \(aspect)"
    }
}
