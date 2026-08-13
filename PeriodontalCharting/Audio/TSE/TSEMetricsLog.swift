//
//  TSEMetricsLog.swift
//  PeriodontalCharting
//
//  WHERE THE NULL DISTRIBUTION ACCUMULATES.
//
//  T1 says "run a week of normal sessions before touching the trigger". A week of
//  console output does not survive a week — Xcode's buffer scrolls, and the sessions
//  that matter most are run from the home screen with no debugger attached. So every
//  measured span is appended to a CSV that outlives the session.
//
//  BUT THE CSV IS NOT HOW YOU READ ONE SESSION. It is how you read a WEEK. At the
//  end of every session an aligned table of that session's spans is printed to the
//  console, because getting a file off an iPad costs an AirDrop or an Xcode
//  container download and reading twenty comma-separated columns by eye is
//  hopeless. The table is for looking; the file is for pooling.
//
//  WHY `print` AND NOT `AppLog`: os_log truncates long messages and does not
//  preserve multi-line layout, so a twenty-column table arrives shredded. The
//  table carries no clinical content — span bounds, levels, distances and metric
//  values, the same material already on the `[Gate/live]` lines.
//
//  ---------------------------------------------------------------------------
//  THE SCHEMA GOES IN THE FILENAME, NOT JUST THE ROWS.
//
//  `spans-2026-08-10.csv` was written with a schema-1 header, then schema-2 rows
//  were appended after a rebuild — 41 fields under 39 columns, every column from
//  `kurt_pooled` rightward shifted by two. The `schema` column let you DETECT the
//  mix but not parse the file; the giveaway was `gini` reading -0.24074, which is
//  impossible for a coefficient bounded in [0, 1].
//
//  A header is written once, at file creation, so a file can only ever be
//  self-consistent if its name pins the schema. `summarise()` now also reads each
//  file's OWN header rather than assuming the first one applies to all of them.
//  ---------------------------------------------------------------------------
//
//  WRITES ARE BUFFERED AND DRAINED OFF THE AUDIO PUMP.
//
//  The first version called `synchronize()` — an fsync — on every span, from inside
//  `record`, which is reached from `GatedAudioProcessor.judgePending`: the SERIAL
//  PUMP that publishes cleaned audio to WhisperKit, where everything happens before
//  `notify?(cleaned)`. A blocking disk flush with unpredictable latency, sitting
//  directly on the transcription path.
//
//  AND THE DURABILITY ARGUMENT FOR IT WAS WRONG. `FileHandle.write` hands the bytes
//  to the kernel; an app crash or a jetsam does NOT lose them, because the process
//  dying does not discard the page cache. fsync only defends against kernel panic
//  or power loss.
//
//  WHAT IS IN THE FILE: numbers. No audio, no transcribed text, no patient
//  identifier. It still goes through `ProtectedStorage`, and protection is
//  re-applied after creation because an atomic write replaces the inode.
//
//  AND LABEL NON-BASELINE SESSIONS. A session containing a second speaker is the
//  one thing that must never enter the null distribution. `startSession(profile:)`
//  is what separates them; give an overlap recording its own profile name.
//

import Foundation
import OSLog

final class TSEMetricsLog: @unchecked Sendable {

    static let shared = TSEMetricsLog()

    // Rows accumulated before the writer forces an fsync.
    private static let syncEveryRows = 32

    // Guards the fields the AUDIO PUMP touches. Held for an array append, nothing more.
    private let lock = NSLock()

    // Owns `handle`, `currentKey` and `rowsSinceSync` EXCLUSIVELY.
    private let writer = DispatchQueue(label: "tse.metrics.writer", qos: .utility)

    private var pending: [String] = []
    // The session's rows, kept for the end-of-session table. Cleared on start, so
    // memory is bounded by one session — a few hundred short strings at worst.
    private var sessionRows: [String] = []
    private var sessionTag = "unlabelled"

    private var handle: FileHandle?          // writer queue only
    private var currentKey = ""              // writer queue only
    private var rowsSinceSync = 0            // writer queue only

    private init() {}

    // MARK: Directory

    private static var directory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        return ProtectedStorage.makeSecureDirectory(
            at: support.appendingPathComponent("TSEMetrics", isDirectory: true))
    }

    static var files: [URL] {
        guard let directory else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "csv" }.sorted { $0.path < $1.path }
    }

    // MARK: Session

    // Label the rows that follow. Called next to `resetTimeline()` — same place and
    // same reason: stream time restarts at 0, so without a label two sessions'
    // rows are indistinguishable once they are in one file.
    //
    // GIVE AN OVERLAP RECORDING ITS OWN PROFILE NAME.
    func startSession(profile: String) {
        lock.lock()
        sessionRows.removeAll(keepingCapacity: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        sessionTag = "\(profile)@\(stamp)"
        let tag = sessionTag
        lock.unlock()

        writer.async { [weak self] in self?.drain(sync: true) }
        print("[TSE/m] session \(tag) — schema \(TSEMetricsConfig.schemaVersion)")
    }

    // Flush, force to disk, and PRINT THE SESSION TABLE.
    //
    // Safe to call more than once and safe never to call — every `record`
    // schedules its own drain — but this is where the table comes from, so a
    // session that ends without it leaves you reading the CSV instead.
    func endSession() {
        lock.lock()
        let rows = sessionRows
        let tag = sessionTag
        lock.unlock()

        writer.async { [weak self] in self?.drain(sync: true) }
        Self.printTable(rows: rows, title: tag)
    }

    // MARK: Recording

    // Called from the audio pump. An array append and a dispatch, nothing else.
    func record(_ span: RescuedSpan, tag: String) {
        guard TSEMetricsConfig.enabled, let metrics = span.metrics else { return }

        lock.lock()
        let session = sessionTag
        lock.unlock()

        let row = Self.csvRow(span, metrics: metrics, tag: tag, session: session)

        lock.lock()
        sessionRows.append(row)
        if TSEMetricsConfig.writeCSV { pending.append(row) }
        lock.unlock()

        if TSEMetricsConfig.writeCSV {
            writer.async { [weak self] in self?.drain(sync: false) }
        }
    }

    // Writer queue ONLY. Multiple queued drains are harmless — whichever runs
    // first takes the batch and the rest find nothing.
    private func drain(sync forceSync: Bool) {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        if batch.isEmpty {
            if forceSync, let handle { try? handle.synchronize(); rowsSinceSync = 0 }
            return
        }
        guard let handle = handleForToday() else { return }

        let text = batch.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)

        rowsSinceSync += batch.count
        if forceSync || rowsSinceSync >= Self.syncEveryRows {
            try? handle.synchronize()
            rowsSinceSync = 0
        }
    }

    // Writer queue ONLY.
    //
    // THE FILENAME CARRIES THE SCHEMA. A header is written once, at creation, so a
    // day-keyed file that outlives a rebuild ends up with rows of two shapes under
    // one header. Keying on day AND schema means a file is always self-consistent
    // and the mismatch becomes impossible rather than merely detectable.
    private func handleForToday() -> FileHandle? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        let key = "\(day)-s\(TSEMetricsConfig.schemaVersion)"
        if key == currentKey, let handle { return handle }

        try? handle?.close()
        handle = nil
        guard let directory = Self.directory else { return nil }
        let url = directory.appendingPathComponent("spans-\(key).csv")
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: url.path)
        if isNew {
            fm.createFile(atPath: url.path, contents: nil)
            ProtectedStorage.secure(url)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        try? opened.seekToEnd()
        if isNew, let header = (Self.header + "\n").data(using: .utf8) {
            try? opened.write(contentsOf: header)
        }
        handle = opened
        currentKey = key
        rowsSinceSync = 0
        return opened
    }

    // MARK: CSV

    static let header = [
        "schema", "session", "tag", "start_s", "end_s", "dur_s",
        "rms", "crest", "clip", "floor", "loud", "speech_s", "frames", "active", "voiced",
        "d_mixed", "verdict", "routed", "d_sep",
        "kurt_span", "kurt_active", "kurt_med", "kurt_p10",
        "gini", "hoyer", "flat_med",
        "cpp_med", "hnr_med", "ac_med", "peaks_mean", "peaks_max", "f0_med", "f0_iqr",
        "off_tang", "off_chance", "off_norm", "near_tmpl", "tmpl_spread", "rank",
        "sub_n", "sub_dmin", "sub_dmax", "sub_spread", "sub_dmean"
    ].joined(separator: ",")

    private static func csvRow(_ span: RescuedSpan,
                               metrics: OverlapMetrics,
                               tag: String,
                               session: String) -> String {
        func f(_ v: Double?) -> String {
            guard let v, v.isFinite else { return "nan" }
            return String(format: "%.5f", v)
        }
        let s = metrics.signal
        let c = metrics.subspace
        let e = metrics.subwindows

        var fields: [String] = [
            "\(TSEMetricsConfig.schemaVersion)",
            "\"\(session)\"",
            tag,
            f(span.startSeconds), f(span.endSeconds), f(span.durationSeconds),
            f(Double(span.level)), f(s.crestFactor), f(s.clippedFraction),
            f(s.noiseFloor), f(s.loudLevel), f(s.speechSeconds),
            "\(s.frames)", "\(s.activeFrames)", "\(s.voicedFrames)",
            f(span.distanceMixed), span.verdictMixed.rawValue,
            span.routed ? "1" : "0", f(span.distanceSeparated),
            f(s.kurtosisSpan), f(s.kurtosisActive), f(s.kurtosisMedian), f(s.kurtosisP10),
            f(s.tfGini), f(s.tfHoyer), f(s.flatnessMedian),
            f(s.cppMedian), f(s.hnrMedian), f(s.autocorrMedian), f(s.competingPeaksMean),
            "\(s.competingPeaksMax)", f(s.f0Median), f(s.f0IQR)
        ]
        fields += [f(c?.tangentialOffRatio), f(c?.chanceRatio), f(c?.offSubspaceNormalised),
                   f(c?.nearestTemplate), f(c?.templateSpread), "\(c?.subspaceRank ?? 0)"]
        fields += ["\(e?.count ?? 0)", f(e?.minDistance), f(e?.maxDistance),
                   f(e?.spread), f(e?.meanDistance)]
        return fields.joined(separator: ",")
    }

    // MARK: - The console table

    // One printed column: which CSV field it reads, how wide, how many decimals.
    //
    // Bound by NAME rather than by index on purpose. Index-based extraction is what
    // produced the shifted schema-2 rows in the first place, and a table that
    // silently mislabels its own columns is worse than no table.
    private struct Column {
        let title: String
        let source: String
        let width: Int
        let decimals: Int?      // nil = print the raw field
    }

    // Twenty of the forty-four columns — the ones worth reading span by span.
    // Everything omitted is either context you already have on the `[Gate/live]`
    // line above, or a diagnostic you go to the CSV for.
    private static let tableColumns: [Column] = [
        Column(title: "start",  source: "start_s",     width: 6, decimals: 2),
        Column(title: "end",    source: "end_s",       width: 6, decimals: 2),
        Column(title: "dur",    source: "dur_s",       width: 5, decimals: 2),
        Column(title: "spch",   source: "speech_s",    width: 5, decimals: 2),
        Column(title: "act",    source: "active",      width: 4, decimals: nil),
        Column(title: "frm",    source: "frames",      width: 4, decimals: nil),
        Column(title: "d",      source: "d_mixed",     width: 6, decimals: 3),
        Column(title: "verdict", source: "verdict",    width: 8, decimals: nil),
        Column(title: "kurtS",  source: "kurt_span",   width: 6, decimals: 2),
        Column(title: "kurtA",  source: "kurt_active", width: 6, decimals: 2),
        Column(title: "crest",  source: "crest",       width: 5, decimals: 1),
        Column(title: "clip",   source: "clip",        width: 5, decimals: 3),
        Column(title: "gini",   source: "gini",        width: 5, decimals: 3),
        Column(title: "flat",   source: "flat_med",    width: 6, decimals: 1),
        Column(title: "cpp",    source: "cpp_med",     width: 5, decimals: 2),
        Column(title: "hnr",    source: "hnr_med",     width: 5, decimals: 1),
        Column(title: "peaks",  source: "peaks_mean",  width: 5, decimals: 2),
        Column(title: "f0",     source: "f0_med",      width: 6, decimals: 1),
        Column(title: "f0iqr",  source: "f0_iqr",      width: 6, decimals: 1),
        Column(title: "offN",   source: "off_norm",    width: 5, decimals: 2),
        Column(title: "subN",   source: "sub_n",       width: 4, decimals: nil),
        Column(title: "subD",   source: "sub_spread",  width: 6, decimals: 3)
    ]

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.suffix(width))
                            : String(repeating: " ", count: width - text.count) + text
    }

    // Print one session's spans as an aligned table.
    //
    // READING ORDER, and what each column is for:
    //   act/frm   HOW MUCH WAS ACTUALLY MEASURED. Check this before believing any
    //             frame-derived column — a row with act 1 of frm 156 has its
    //             kurtA, cpp, hnr, peaks and f0 computed from a single frame.
    //             `spch` should also match the seconds of speech on the matching
    //             `[Gate] keep` line; divergence means the activity threshold has
    //             regressed.
    //   crest/clip  THE KURTOSIS CONTROL. kurtS is scale-invariant, so gain cannot
    //             move it — but the limiter is nonlinear and moves it both ways.
    //             A kurtS excursion at crest 4 / clip 0 is real; the same at
    //             crest 2 is the limiter.
    //   kurtS/kurtA  OPPOSITE SIGN CONVENTIONS BY DESIGN. kurtS should be positive
    //             and FALL under mixing; kurtA sits near zero and RISES. They
    //             disagreeing is informative, not a bug.
    //   peaks/f0iqr  the harmonic family. f0iqr widening past ~20 Hz means either
    //             two speakers or octave errors.
    //   subD      max minus min distance across fixed sub-windows. Single-speaker
    //             spans measured 0.016–0.033; a span where a second voice was
    //             present measured 0.333.
    static func printTable(rows: [String], title: String) {
        guard !rows.isEmpty else {
            print("[TSE/m] session \(title) ended — no spans measured")
            return
        }
        let names = header.split(separator: ",").map(String.init)
        var index: [String: Int] = [:]
        for (i, name) in names.enumerated() { index[name] = i }

        print("")
        print("[TSE/m] SESSION \(title) — schema \(TSEMetricsConfig.schemaVersion), "
              + "\(rows.count) span(s)")
        print("[TSE/m] " + tableColumns.map { pad($0.title, $0.width) }.joined(separator: " "))

        for row in rows {
            // The session tag is quoted and contains no comma, so a plain split is
            // safe here — but only here. Do not reuse this for arbitrary CSV.
            let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            var cells: [String] = []
            for column in tableColumns {
                guard let i = index[column.source], i < fields.count else {
                    cells.append(pad("?", column.width)); continue
                }
                let raw = fields[i]
                if let decimals = column.decimals {
                    if let value = Double(raw), value.isFinite {
                        cells.append(pad(String(format: "%.\(decimals)f", value), column.width))
                    } else {
                        cells.append(pad("-", column.width))
                    }
                } else {
                    cells.append(pad(raw, column.width))
                }
            }
            print("[TSE/m] " + cells.joined(separator: " "))
        }
        print("")
    }

    // MARK: Readback

    // Print the percentile table for everything collected so far, straight to the
    // console. The same text the debug menu's report view shows.
    static func printSummary() {
        print(summarise())
    }

    // p5 / p25 / p50 / p75 / p95 for every numeric column across every collected
    // file, grouped by schema and then by the gate's own verdict.
    //
    // THIS IS THE DELIVERABLE OF T1, not the CSV itself. Read `accept` against
    // `confirm`/`reject` separately: the second group is mostly quiet-you, which is
    // the population the current trigger misclassifies, and a metric that does not
    // separate the two is not a candidate.
    //
    // EACH FILE IS PARSED AGAINST ITS OWN HEADER. Assuming the first file's header
    // applied to all of them is how a schema-1 header ended up governing schema-2
    // rows; per-schema filenames make that unlikely, but reading the header per
    // file makes it impossible.
    static func summarise() -> String {
        // (schema, verdict, column name) -> values
        var byColumn: [String: [String: [String: [Double]]]] = [:]
        var counts: [String: Int] = [:]
        var fileCount = 0

        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let head = lines.first else { continue }
            fileCount += 1
            let names = head.split(separator: ",").map(String.init)
            guard let schemaIndex = names.firstIndex(of: "schema"),
                  let verdictIndex = names.firstIndex(of: "verdict") else { continue }
            lines.removeFirst()

            for line in lines {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == names.count,
                      schemaIndex < fields.count, verdictIndex < fields.count else { continue }
                let schema = fields[schemaIndex]
                let verdict = fields[verdictIndex]
                counts["\(schema)|\(verdict)", default: 0] += 1
                for (i, name) in names.enumerated() where i > 5 {
                    guard let value = Double(fields[i]), value.isFinite else { continue }
                    byColumn[schema, default: [:]][verdict, default: [:]][name, default: []].append(value)
                }
            }
        }

        guard !byColumn.isEmpty else { return "[TSE/m] no rows collected yet" }

        func percentiles(_ values: [Double]) -> String {
            let clean = values.sorted()
            guard clean.count >= 5 else { return "n<5" }
            func at(_ p: Double) -> Double {
                let position = p * Double(clean.count - 1)
                let low = Int(position.rounded(.down))
                let high = Swift.min(clean.count - 1, low + 1)
                let fraction = position - Double(low)
                return clean[low] * (1 - fraction) + clean[high] * fraction
            }
            return String(format: "n%4d  p5 %8.3f  p25 %8.3f  p50 %8.3f  p75 %8.3f  p95 %8.3f",
                          clean.count, at(0.05), at(0.25), at(0.50), at(0.75), at(0.95))
        }

        var out = "[TSE/m] null distribution — \(fileCount) file(s)\n"
        for schema in byColumn.keys.sorted() {
            out += "\n=== schema \(schema)\n"
            for verdict in ["accept", "confirm", "reject", "tooShort"] {
                guard let columns = byColumn[schema]?[verdict] else { continue }
                out += "\n--- verdict = \(verdict) "
                out += "(\(counts["\(schema)|\(verdict)"] ?? 0) spans)\n"
                for name in columns.keys.sorted() {
                    out += "  " + name.padding(toLength: 12, withPad: " ", startingAt: 0)
                    out += " " + percentiles(columns[name] ?? []) + "\n"
                }
            }
        }
        return out
    }
}
