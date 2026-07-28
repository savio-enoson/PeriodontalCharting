import SwiftUI
import UIKit

// MARK: - ToothAssetOffsets
struct ToothAssetOffsets {
    
    // The ratio of the tooth's non-transparent pixel width precisely at the CEJ line (the tooth base/neck)
    // compared to the total PNG asset width. Used to dynamically size implants to the physical tooth base.
    static let cejWidthRatios: [String: CGFloat] = [
        "11_B": 0.8202, "11_P": 0.7086, "12_B": 0.693,  "12_P": 0.6792,
        "13_B": 0.7769, "13_P": 0.6217, "14_B": 0.7769, "14_P": 0.6639,
        "15_B": 0.7037, "15_P": 0.6861, "16_B": 0.8667, "16_P": 0.7832,
        "17_B": 0.8133, "17_P": 0.6016, "18_B": 0.8246, "18_P": 0.7108,
        "21_B": 0.8202, "21_P": 0.7086, "22_B": 0.693,  "22_P": 0.6792,
        "23_B": 0.7769, "23_P": 0.6217, "24_B": 0.7769, "24_P": 0.6639,
        "25_B": 0.7037, "25_P": 0.6861, "26_B": 0.8667, "26_P": 0.7832,
        "27_B": 0.8133, "27_P": 0.6016, "28_B": 0.8246, "28_P": 0.7108,
        "31_B": 0.6611, "31_L": 0.6258, "32_B": 0.6437, "32_L": 0.6139,
        "33_B": 0.6739, "33_L": 0.5867, "34_B": 0.5797, "34_L": 0.6278,
        "35_B": 0.5945, "35_L": 0.6056, "36_B": 0.7919, "36_L": 0.8122,
        "37_B": 0.8116, "37_L": 0.7184, "38_B": 0.8637, "38_L": 0.6296,
        "41_B": 0.6611, "41_L": 0.6258, "42_B": 0.6437, "42_L": 0.6139,
        "43_B": 0.6739, "43_L": 0.5867, "44_B": 0.5797, "44_L": 0.6278,
        "45_B": 0.5945, "45_L": 0.6056, "46_B": 0.7919, "46_L": 0.8122,
        "47_B": 0.8116, "47_L": 0.7184, "48_B": 0.8637, "48_L": 0.6296,
    ]
    
    // Arrays defining the custom scaling and horizontal offsets for implant screws.x 7 = 3rd molar).
    // Provide exactly 8 values per array.
    // These values are SCREEN POINT offsets added directly to the vertical position of the tooth.
    // Use negative values to move the tooth UP, positive to move it DOWN.
    static let upperBuccal: [CGFloat]  = [23, 13, 7, 11, 4, 1, 1, 5]
    static let upperPalatal: [CGFloat] = [-6, -4, 3, -1, -3, -2, 1, 0]
    static let lowerBuccal: [CGFloat]  = [-14, -10, -7, -7, -6, -8, -12, -11]
    static let lowerLingual: [CGFloat] = [6, 4, -3, 8, 3, -1, -5, -6]
    
    // Optional X offsets to horizontally align the implant screw with asymmetrical tooth crowns
    static let upperBuccalX: [CGFloat]  = [0, 0, 0, 0, 0, 0, 0, 0]
    static let upperPalatalX: [CGFloat] = [0, 0, 0, 0, 0, 0, 0, 0]
    static let lowerBuccalX: [CGFloat]  = [0, 0, 0, 0, 0, 0, 0, 0]
    static let lowerLingualX: [CGFloat] = [0, 0, 0, 0, 0, 0, 0, 0]
    
    // Optional scaling multipliers for the implant screw (default 1.0)
    static let upperBuccalScale: [CGFloat]  = [1, 1, 1, 1, 1, 1, 1, 1]
    static let upperPalatalScale: [CGFloat] = [1, 1, 1, 1, 1, 1, 1, 1]
    static let lowerBuccalScale: [CGFloat]  = [1, 1, 1, 1, 1, 1, 1, 1]
    static let lowerLingualScale: [CGFloat] = [1, 1, 1, 1, 1, 1, 1, 1]
    
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
    
    static func offsetX(for tooth: ToothObject, isOuter: Bool) -> CGFloat {
        let quadrant = tooth.toothNumber / 10
        let id = tooth.toothNumber % 10
        guard id >= 1 && id <= 8 else { return 0 }
        
        let arrayIndex = id - 1
        
        switch quadrant {
        case 1, 2:
            let arr = isOuter ? upperBuccalX : upperPalatalX
            let val = arrayIndex < arr.count ? arr[arrayIndex] : 0
            return quadrant == 2 ? -val : val // Mirror X offset for left side
        case 3, 4:
            let arr = isOuter ? lowerBuccalX : lowerLingualX
            let val = arrayIndex < arr.count ? arr[arrayIndex] : 0
            return quadrant == 4 ? -val : val // Mirror X offset for left side
        default:
            return 0
        }
    }
    
    static func scale(for tooth: ToothObject, isOuter: Bool) -> CGFloat {
        let quadrant = tooth.toothNumber / 10
        let id = tooth.toothNumber % 10
        guard id >= 1 && id <= 8 else { return 1.0 }
        
        let arrayIndex = id - 1
        
        switch quadrant {
        case 1, 2:
            let arr = isOuter ? upperBuccalScale : upperPalatalScale
            return arrayIndex < arr.count ? arr[arrayIndex] : 1.0
        case 3, 4:
            let arr = isOuter ? lowerBuccalScale : lowerLingualScale
            return arrayIndex < arr.count ? arr[arrayIndex] : 1.0
        default:
            return 1.0
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
                if let img = uiImage {
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

                if tooth.implant {
                    let screwXOffset = ToothAssetOffsets.offsetX(for: tooth, isOuter: isOuter)
                    let screwScale = ToothAssetOffsets.scale(for: tooth, isOuter: isOuter)
                    
                    let suffix = isOuter ? "B" : (tooth.toothNumber < 30 ? "P" : "L")
                    let toothKey = "\(tooth.toothNumber)_\(suffix)"
                    let cejRatio = ToothAssetOffsets.cejWidthRatios[toothKey] ?? 0.65
                    let trueToothBaseWidth = targetWidth * cejRatio
                    
                    let endWidth = trueToothBaseWidth * screwScale
                    let isMolar = [6, 7, 8].contains(tooth.toothNumber % 10)
                    let bodyWidth = isMolar ? (endWidth * 0.80) : endWidth
                    
                    VStack(spacing: -1) { // Negative spacing prevents 1px hairline rendering gaps
                        if !isMirrored {
                            // Upper jaw: Root points UP. CEJ is at the bottom of the root region.
                            ZStack(alignment: .bottom) {
                                Rectangle().fill(Color(.systemBackground))
                                    .frame(width: targetWidth, height: rootHeight)
                                
                                VStack(spacing: -1) {
                                    Image("implant_screw_body")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: bodyWidth)
                                    
                                    if isMolar {
                                        Image("implant_screw_end")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: endWidth)
                                    }
                                }
                                .offset(x: screwXOffset)
                            }
                            .frame(width: targetWidth, height: rootHeight)
                            Spacer(minLength: 0)
                        } else {
                            // Lower jaw: Root points DOWN. CEJ is at the top of the root region.
                            Spacer(minLength: 0)
                            ZStack(alignment: .top) {
                                Rectangle().fill(Color(.systemBackground))
                                    .frame(width: targetWidth, height: rootHeight)
                                
                                VStack(spacing: -1) {
                                    Image("implant_screw_body")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: bodyWidth)
                                    
                                    if isMolar {
                                        Image("implant_screw_end")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: endWidth)
                                    }
                                }
                                .scaleEffect(y: -1)
                                .offset(x: screwXOffset)
                            }
                            .frame(width: targetWidth, height: rootHeight)
                        }
                    }
                    .frame(width: targetWidth, height: 240)
                    .position(x: targetWidth / 2.0, y: 120)
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
            ZStack {
                chartLinesOverlay()
                    .zIndex(0)
                furcationOverlay()
                    .zIndex(1)
            }
        }
        .frame(height: 240)
        .drawingGroup()
    }
    
    @ViewBuilder
    private func furcationOverlay() -> some View {
        if !tooth.missing && !tooth.implant {
            let furcations = isOuter ? tooth.furcation?.outer : tooth.furcation?.inner
            if let furcations = furcations, !furcations.isEmpty {
                let targetCEJLine: CGFloat = isMirrored ? 90.0 : 150.0
                let yPos = targetCEJLine + (isMirrored ? 20.0 : -20.0)
                
                ForEach(0..<furcations.count, id: \.self) { i in
                    let val = furcations[i]
                    if val != .zero {
                        let xPos: CGFloat = furcations.count == 1 ? targetWidth / 2.0 : (i == 0 ? targetWidth * 0.25 : targetWidth * 0.75)
                        FurcationShape(value: val)
                            .frame(width: 14, height: 14)
                            .position(x: xPos, y: yPos)
                    }
                }
            }
        }
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
