//
//  TSEMetricsLog.swift
//  PeriodontalCharting
//
//  THE CONSOLE IS THE TABLE.
//
//  One aligned row per span, printed as the span is judged, with the column header
//  printed once when the session starts. Select the `[TSE/m]` lines in Xcode, copy,
//  done — no file, no export, no waiting for a clean stop.
//
//  THERE IS NO PERSISTENCE, DELIBERATELY. An earlier version wrote a CSV under
//  Application Support so a week of sessions could accumulate into the null
//  distribution T1 asks for. It was removed while the metric definitions are still
//  moving — five schema revisions in two days — because during design work the file
//  is pure friction: getting it off an iPad costs an AirDrop or an Xcode container
//  download, and forty comma-separated columns are unreadable by eye. When the
//  definitions settle and collection starts for real, console output will not
//  survive a week and persistence has to come back; it is in git history, in the
//  commit that added schema 5.
//
//  WHY `print` AND NOT `AppLog`: os_log truncates long messages and does not
//  preserve layout, so an aligned row arrives shredded. The rows carry no clinical
//  content — span bounds, levels, distances and metric values, the same material
//  already on the `[Gate/live]` line above each one.
//
//  ONE TABLE DEFINITION. `columns` carries the title, the width AND the value
//  extractor for each column, so the header and the rows are generated from the
//  same array and cannot drift apart. The previous version formatted a CSV line and
//  re-parsed it by column name; that indirection existed only to serve the file,
//  and with the file gone the whole class of index/name mismatch goes with it.
//
//  LABEL NON-BASELINE SESSIONS. A session containing a second speaker is the one
//  thing that must never be pooled with single-speaker baseline. `startSession`
//  stamps a profile name and timestamp on the header line — read it before reading
//  the rows.
//

import Foundation

final class TSEMetricsLog: @unchecked Sendable {

    static let shared = TSEMetricsLog()

    // `sessionTag` is written from the main actor by `startSession` and read from
    // the audio pump by `record`; `spanCount` is written from the pump and read at
    // session end. Held for a string copy and an increment, nothing more.
    private let lock = NSLock()
    private var sessionTag = "unlabelled"
    private var spanCount = 0

    private init() {}

    // MARK: - Session

    // Label the rows that follow AND print the column header, so everything after
    // this line reads as one table.
    //
    // Called next to `resetTimeline()` — same place and same reason: stream time
    // restarts at 0 every session, so without a label two sessions are
    // indistinguishable in a scrolled-back console.
    func startSession(profile: String) {
        lock.lock()
        spanCount = 0
        sessionTag = "\(profile)@\(ISO8601DateFormatter().string(from: Date()))"
        let tag = sessionTag
        lock.unlock()

        guard TSEMetricsConfig.logToConsole else { return }
        print("")
        print("[TSE/m] SESSION \(tag) — schema \(TSEMetricsConfig.schemaVersion)")
        print("[TSE/m] " + Self.headerLine())
    }

    // Re-print the header with a count, so a long session ends with the legend
    // still on screen rather than scrolled away. Safe to call more than once, and
    // safe never to call — every `record` has already printed its own row.
    func endSession() {
        lock.lock()
        let count = spanCount
        let tag = sessionTag
        lock.unlock()

        guard TSEMetricsConfig.logToConsole else { return }
        print("[TSE/m] " + Self.headerLine())
        print("[TSE/m] SESSION \(tag) ended — \(count) span(s) measured")
        print("")
    }

    // MARK: - Recording

    // Called from the audio pump, inside `GatedAudioProcessor.judgePending` —
    // before `notify?(cleaned)` hands audio to WhisperKit. One `print` and one
    // increment; nothing here touches disk.
    func record(_ span: RescuedSpan, tag: String) {
        guard TSEMetricsConfig.enabled,
              TSEMetricsConfig.logToConsole,
              let metrics = span.metrics else { return }

        lock.lock()
        spanCount += 1
        lock.unlock()

        print("[TSE/m] " + Self.row(for: span, metrics: metrics))
    }

    // MARK: - The table

    // Title, width, and how to get the value — all three in one place, so the
    // header and the rows are generated from the same declaration.
    private struct Column {
        let title: String
        let width: Int
        let value: (RescuedSpan, OverlapMetrics) -> String
    }

    private static func num(_ v: Double?, _ decimals: Int) -> String {
        guard let v, v.isFinite else { return "-" }
        return String(format: "%.\(decimals)f", v)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.suffix(width))
                            : String(repeating: " ", count: width - text.count) + text
    }

    // READING ORDER, and what each column is for:
    //
    //   act/frm   HOW MUCH WAS ACTUALLY MEASURED. Read this before believing any
    //             frame-derived column — a span with act 1 of frm 156 has its
    //             kurtA, cpp, hnr, peaks and f0 computed from a single frame.
    //             `spch` should match the seconds of speech on the matching
    //             `[Gate] keep` line; divergence means the activity threshold has
    //             regressed.
    //   crest/clip  THE KURTOSIS CONTROL. kurtS is scale-invariant so gain cannot
    //             move it, but the limiter is nonlinear and moves it both ways —
    //             squashing peaks pulls it down, clipping pushes it up. A kurtS
    //             excursion at crest 4-5 with clip 0 is real; the same at crest 2
    //             is the limiter.
    //   kurtS/kurtA  OPPOSITE SIGN CONVENTIONS BY DESIGN. kurtS is the classical
    //             super-Gaussian measure and should FALL under mixing; kurtA sits
    //             near zero and RISES. A gap under ~1 means the activity threshold
    //             is too loose and the two have collapsed into one measurement.
    //   f0iqr     the strongest overlap signal so far. Measured 17.8 clean, 70.6
    //             with overlap, 133-141 where another voice dominated — and 19.3 on
    //             a clean span of a DIFFERENT speaker, which is the case that must
    //             reject rather than route to the extractor.
    //   subD      max minus min distance across fixed sub-windows. 0.016-0.033
    //             single-speaker, 0.164-0.333 where a second voice was present.
    private static let columns: [Column] = [
        Column(title: "start",   width: 6, value: { s, _ in num(s.startSeconds, 2) }),
        Column(title: "end",     width: 6, value: { s, _ in num(s.endSeconds, 2) }),
        Column(title: "dur",     width: 5, value: { s, _ in num(s.durationSeconds, 2) }),
        Column(title: "spch",    width: 5, value: { _, m in num(m.signal.speechSeconds, 2) }),
        Column(title: "act",     width: 4, value: { _, m in "\(m.signal.activeFrames)" }),
        Column(title: "frm",     width: 4, value: { _, m in "\(m.signal.frames)" }),
        Column(title: "d",       width: 6, value: { s, _ in num(s.distanceMixed, 3) }),
        Column(title: "verdict", width: 8, value: { s, _ in s.verdictMixed.rawValue }),
        Column(title: "kurtS",   width: 6, value: { _, m in num(m.signal.kurtosisSpan, 2) }),
        Column(title: "kurtA",   width: 6, value: { _, m in num(m.signal.kurtosisActive, 2) }),
        Column(title: "crest",   width: 5, value: { _, m in num(m.signal.crestFactor, 1) }),
        Column(title: "clip",    width: 5, value: { _, m in num(m.signal.clippedFraction, 3) }),
        Column(title: "gini",    width: 5, value: { _, m in num(m.signal.tfGini, 3) }),
        Column(title: "flat",    width: 6, value: { _, m in num(m.signal.flatnessMedian, 1) }),
        Column(title: "cpp",     width: 5, value: { _, m in num(m.signal.cppMedian, 2) }),
        Column(title: "hnr",     width: 5, value: { _, m in num(m.signal.hnrMedian, 1) }),
        Column(title: "peaks",   width: 5, value: { _, m in num(m.signal.competingPeaksMean, 2) }),
        Column(title: "f0",      width: 6, value: { _, m in num(m.signal.f0Median, 1) }),
        Column(title: "f0iqr",   width: 6, value: { _, m in num(m.signal.f0IQR, 1) }),
        Column(title: "offN",    width: 5, value: { _, m in num(m.subspace?.offSubspaceNormalised, 2) }),
        Column(title: "subN",    width: 4, value: { _, m in "\(m.subwindows?.count ?? 0)" }),
        Column(title: "subD",    width: 6, value: { _, m in num(m.subwindows?.spread, 3) })
    ]

    static func headerLine() -> String {
        columns.map { pad($0.title, $0.width) }.joined(separator: " ")
    }

    static func row(for span: RescuedSpan, metrics: OverlapMetrics) -> String {
        columns.map { pad($0.value(span, metrics), $0.width) }.joined(separator: " ")
    }
}
