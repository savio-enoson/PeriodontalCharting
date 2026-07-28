import SwiftUI

// MARK: - ToothColumnView

struct ToothColumnView: View {
    var teeth: [ToothObject]
    var index: Int
    var isUpperJaw: Bool
    var onToothUpdate: ((ToothObject) -> Void)?

    @EnvironmentObject var selectionModel: ChartSelectionModel

    private var tooth: ToothObject { teeth[index] }
    
    enum ActivePopover: Identifiable, Equatable {
        case mobility
        case furcation(isOuter: Bool, site: Int)
        case gm(isOuter: Bool, site: Int)
        case pd(isOuter: Bool, site: Int)
        var id: String { String(describing: self) }
    }
    @State private var activePopover: ActivePopover?

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

    private var columnWidth: CGFloat {
        let outerName = imageName(for: tooth, isOuter: true)
        let innerName = imageName(for: tooth, isOuter: false)
        let scaleFactor: CGFloat = 72.0 / 591.0
        
        let w1 = UIImage(named: outerName).map { ($0.size.width * $0.scale) * scaleFactor } ?? 72.0
        let w2 = UIImage(named: innerName).map { ($0.size.width * $0.scale) * scaleFactor } ?? 72.0
        
        let rawMax = max(w1, w2)
        return max(rawMax, 48.0)
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

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 4) {
                Text("\(tooth.toothNumber)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        var m = tooth
                        m.missing.toggle()
                        onToothUpdate?(m)
                    }

                VStack(spacing: 4) {
                    sharedGrid()
                    Color(.separator).frame(height: 1)
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
        .frame(width: columnWidth)
        .frame(width: columnWidth)
        .fullScreenCover(item: $activePopover) { pop in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { activePopover = nil }
                
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        
                        VStack(spacing: 0) {
                    switch pop {
                    case .mobility:
                        NumberPadPopoverView(
                            isPresented: Binding(get: { activePopover != nil }, set: { if !$0 { activePopover = nil } }),
                            currentValue: tooth.mobility.rawValue,
                            onValueSelected: { val in
                                if let m = MobilityClass(rawValue: val) {
                                    var t = tooth; t.mobility = m; onToothUpdate?(t)
                                }
                            }
                        )
                    case .furcation(let o, let site):
                        let vals = o ? tooth.furcation?.outer : tooth.furcation?.inner
                        let current = (vals != nil && site < vals!.count) ? vals![site].rawValue : 0
                        NumberPadPopoverView(
                            isPresented: Binding(get: { activePopover != nil }, set: { if !$0 { activePopover = nil } }),
                            currentValue: current,
                            onValueSelected: { val in
                                if let f = FurcationClass(rawValue: val) {
                                    var t = tooth
                                    if o { t.furcation?.outer[site] = f } else { t.furcation?.inner[site] = f }
                                    onToothUpdate?(t)
                                }
                            }
                        )
                    case .gm(let o, let site):
                        let current = o ? tooth.gingivalMargin.outer[site] : tooth.gingivalMargin.inner[site]
                        NumberPadPopoverView(
                            isPresented: Binding(get: { activePopover != nil }, set: { if !$0 { activePopover = nil } }),
                            currentValue: current,
                            onValueSelected: { val in
                                var t = tooth
                                if o { t.gingivalMargin.outer[site] = val } else { t.gingivalMargin.inner[site] = val }
                                onToothUpdate?(t)
                            }
                        )
                    case .pd(let o, let site):
                        let current = o ? tooth.probingDepth.outer[site] : tooth.probingDepth.inner[site]
                        NumberPadPopoverView(
                            isPresented: Binding(get: { activePopover != nil }, set: { if !$0 { activePopover = nil } }),
                            currentValue: current,
                            onValueSelected: { val in
                                var t = tooth
                                if o { t.probingDepth.outer[site] = val } else { t.probingDepth.inner[site] = val }
                                onToothUpdate?(t)
                            }
                        )
                    }
                        }
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.black.opacity(0.15), radius: 20, y: 10)
                        
                        Spacer().frame(width: 80) // Reserved for zoom slider
                    }
                    Spacer().frame(height: 40)
                }
            }
            .presentationBackground(.clear)
        }
    }

    // MARK: Tooth Graphic

    @ViewBuilder
    private func toothGraphic() -> some View {
        VStack(spacing: 32) {
            if isUpperJaw {
                ToothGraphicSideView(teeth: teeth, index: index, isOuter: true,  isMirrored: false, targetWidth: columnWidth).equatable()
                ToothGraphicSideView(teeth: teeth, index: index, isOuter: false, isMirrored: true, targetWidth: columnWidth).equatable()
            } else {
                ToothGraphicSideView(teeth: teeth, index: index, isOuter: false, isMirrored: false, targetWidth: columnWidth).equatable()
                ToothGraphicSideView(teeth: teeth, index: index, isOuter: true,  isMirrored: true, targetWidth: columnWidth).equatable()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Aspect Grid

    @ViewBuilder
    private func sharedGrid() -> some View {
        VStack(spacing: 0) {
            ImplantCheckCell(isChecked: tooth.implant, isSelected: isCellSelected(op: .implant), isMissing: tooth.missing)
                .contentShape(Rectangle())
                .onTapGesture {
                    var m = tooth
                    m.implant.toggle()
                    onToothUpdate?(m)
                }
            SingleValueCell(value: "\(tooth.mobility.rawValue)", isSelected: isCellSelected(op: .mobility), isMissing: tooth.missing)
                .opacity(tooth.implant ? 0.3 : 1.0)
                .background(Color(.separator))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !tooth.implant else { return }
                    selectionModel.selectedCells = [ChartCellCoordinate(toothNumber: tooth.toothNumber, operation: .mobility, aspect: nil, siteIndex: nil)]
                    activePopover = .mobility
                }
        }
    }

    @ViewBuilder
    private func aspectGrid(isOuter: Bool) -> some View {
        VStack(spacing: 1) {
            FurcationCell(
                furcation: isOuter ? tooth.furcation?.outer : tooth.furcation?.inner,
                selectedSites: selectedSites(for: .furcation, isOuter: isOuter),
                isMissing: tooth.missing,
                onTap: { site in
                    guard !tooth.implant else { return }
                    selectionModel.selectedCells = [ChartCellCoordinate(toothNumber: tooth.toothNumber, operation: .furcation, aspect: isOuter ? .outer : .inner, siteIndex: site)]
                    
                    var newTooth = tooth
                    if isOuter {
                        if var arr = newTooth.furcation?.outer {
                            arr[site] = FurcationClass(rawValue: (arr[site].rawValue + 1) % 4) ?? .zero
                            newTooth.furcation?.outer = arr
                        }
                    } else {
                        if var arr = newTooth.furcation?.inner {
                            arr[site] = FurcationClass(rawValue: (arr[site].rawValue + 1) % 4) ?? .zero
                            newTooth.furcation?.inner = arr
                        }
                    }
                    onToothUpdate?(newTooth)
                }
            )
            .opacity(tooth.implant ? 0.3 : 1.0)
            
            TripleValueRow(
                values: isOuter ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner,
                selectedSites: selectedSites(for: .gingivalMargin, isOuter: isOuter),
                isMissing: tooth.missing,
                onTap: { site in
                    selectionModel.selectedCells = [ChartCellCoordinate(toothNumber: tooth.toothNumber, operation: .gingivalMargin, aspect: isOuter ? .outer : .inner, siteIndex: site)]
                    activePopover = .gm(isOuter: isOuter, site: site)
                }
            )
            TripleValueRow(
                values: isOuter ? tooth.probingDepth.outer  : tooth.probingDepth.inner,
                selectedSites: selectedSites(for: .probingDepth, isOuter: isOuter),
                isMissing: tooth.missing,
                isProbingDepth: true,
                onTap: { site in
                    selectionModel.selectedCells = [ChartCellCoordinate(toothNumber: tooth.toothNumber, operation: .probingDepth, aspect: isOuter ? .outer : .inner, siteIndex: site)]
                    activePopover = .pd(isOuter: isOuter, site: site)
                }
            )
            TripleValueRow(
                values: isOuter ? tooth.attachmentLevel.outer : tooth.attachmentLevel.inner,
                selectedSites: [false, false, false],
                isMissing: tooth.missing
            )
            BoolDotRow(
                values: isOuter ? tooth.bleeding.outer : tooth.bleeding.inner,
                dotColor: .red,
                selectedSites: selectedSites(for: .bleeding, isOuter: isOuter),
                isMissing: tooth.missing,
                onTap: { site in
                    var t = tooth
                    if isOuter { t.bleeding.outer[site].toggle() } else { t.bleeding.inner[site].toggle() }
                    onToothUpdate?(t)
                }
            )
            BoolDotRow(
                values: isOuter ? tooth.plaque.outer   : tooth.plaque.inner,
                dotColor: .blue,
                selectedSites: selectedSites(for: .plaque, isOuter: isOuter),
                isMissing: tooth.missing,
                onTap: { site in
                    var t = tooth
                    if isOuter { t.plaque.outer[site].toggle() } else { t.plaque.inner[site].toggle() }
                    onToothUpdate?(t)
                }
            )
        }
        // 1pt grid background — VStack(spacing:1) gaps reveal this Color as hairlines
        .background(Color(.separator))
    }
}

