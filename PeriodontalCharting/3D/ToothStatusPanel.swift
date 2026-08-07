//
//  ToothStatusPanel.swift
//  PeriodontalCharting
//
//  A compact, read-only readout of one tooth's chart status, shown in the 3-D
//  view when a tooth is tapped. It reuses the same leaf cells the 2-D chart
//  draws its columns from (`TripleValueRow`, `BoolDotRow`) so the numbers, the
//  red "PD ≥ 4" tint and the bleeding/plaque dots read identically to the
//  chart. The cells take an empty `selectedSites` and no `onTap`, so this panel
//  only displays — editing still happens in the chart. Styling follows the
//  app's language: a white card, the brand navy header, systemGray6 sub-panels.
//

import SwiftUI

struct ToothStatusPanel: View {
    let tooth: ToothObject

    /// The app's brand navy — same value the chart's buttons and segmented
    /// controls use.
    private static let brandNavy = Color(red: 0.05, green: 0.2, blue: 0.5)

    /// Inner aspect is palatal on the maxilla, lingual on the mandible.
    private var innerLabel: String {
        let quadrant = tooth.toothNumber / 10
        return (quadrant == 1 || quadrant == 2) ? "Palatal" : "Lingual"
    }

    private var noSites: [Bool] { [false, false, false] }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                if tooth.missing {
                    Label("Missing tooth", systemImage: "xmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    summaryRow
                    aspectSection(title: "Buccal", isOuter: true)
                    aspectSection(title: innerLabel, isOuter: false)
                }
            }
            .padding(14)
        }
        .frame(width: 264)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Tooth \(tooth.toothNumber)")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            if tooth.implant {
                Text("IMPLANT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.22), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Self.brandNavy)
    }

    // MARK: - Summary (mobility / furcation)

    private var summaryRow: some View {
        HStack(spacing: 10) {
            metric(label: "Mobility", value: "\(tooth.mobility.rawValue)")
            if let furc = tooth.furcation, !(furc.outer.isEmpty && furc.inner.isEmpty) {
                metric(label: "Furcation", value: furcationSummary(furc))
            }
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func furcationSummary(_ furc: FurcationData) -> String {
        let maxClass = (furc.outer + furc.inner).map(\.rawValue).max() ?? 0
        return "Class \(maxClass)"
    }

    // MARK: - Aspect section

    private func aspectSection(title: String, isOuter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Self.brandNavy)

            VStack(spacing: 6) {
                labelledRow("PD") {
                    TripleValueRow(values: pd(isOuter), selectedSites: noSites,
                                   isMissing: false, isProbingDepth: true)
                }
                labelledRow("GM") {
                    TripleValueRow(values: gm(isOuter), selectedSites: noSites, isMissing: false)
                }
                labelledRow("CAL") {
                    TripleValueRow(values: cal(isOuter), selectedSites: noSites, isMissing: false)
                }
                labelledRow("BoP") {
                    BoolDotRow(values: bleeding(isOuter), dotColor: .red,
                               selectedSites: noSites, isMissing: false)
                }
                labelledRow("Plaque") {
                    BoolDotRow(values: plaque(isOuter), dotColor: .blue,
                               selectedSites: noSites, isMissing: false)
                }
            }
            .padding(8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func labelledRow<Content: View>(_ label: String,
                                            @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            content()
                .frame(width: 132)
                .background(Color(.separator))    // hairline grid, matching the chart cells
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Data accessors

    private func pd(_ o: Bool) -> [Int] { o ? tooth.probingDepth.outer : tooth.probingDepth.inner }
    private func gm(_ o: Bool) -> [Int] { o ? tooth.gingivalMargin.outer : tooth.gingivalMargin.inner }
    private func cal(_ o: Bool) -> [Int] { o ? tooth.attachmentLevel.outer : tooth.attachmentLevel.inner }
    private func bleeding(_ o: Bool) -> [Bool] { o ? tooth.bleeding.outer : tooth.bleeding.inner }
    private func plaque(_ o: Bool) -> [Bool] { o ? tooth.plaque.outer : tooth.plaque.inner }
}
