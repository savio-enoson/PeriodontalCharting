//
//  ChartAssetStore.swift
//  PeriodontalCharting
//
//  Decode-once, hold-forever store for the four annotation-order diagrams.
//
//  WHY THIS EXISTS. The source PNGs are ~6800 x 1300 each:
//
//      Upper-Outer   6702 x 1389      Lower-Inner   6819 x 1230
//      Upper-Inner   6786 x 1290      Lower-Outer   6822 x 1320
//
//  35.5M pixels total, which is ~142 MB once decoded to ARGB8888 — to fill a
//  strip a few hundred points wide. `Image(name).resizable().scaledToFit()`
//  scales AFTER decode, so the full bitmap is materialised every time.
//
//  They sit in the same `body` as the onboarding name field, so focusing that
//  field or typing one character re-lays-out all four. Under memory pressure
//  from the concurrent ~600 MB model load the decode cache gets evicted and the
//  work happens AGAIN — which is the hitch on tap.
//
//  THE SOURCE FILES ARE NOT MODIFIED. The downscale happens once, in memory, at
//  load time, and the result is retained strongly so nothing can evict it.
//  ~142 MB becomes ~18 MB and every later render is a blit.
//

import SwiftUI
import UIKit
import OSLog

@MainActor
@Observable
final class ChartAssetStore {
    @ObservationIgnored static let shared = ChartAssetStore()

    /// Asset-catalog names, in the order the splash reports them.
    static let names = ["Upper-Outer", "Upper-Inner", "Lower-Inner", "Lower-Outer"]

    /// Longest edge to keep, in pixels. A landscape iPad gives the visualizer
    /// ~1250 pt of width, so 2400 px covers @2x with room to spare and still
    /// throws away ~65% of each source image's linear resolution.
    private static let maxPixelSize: CGFloat = 2400

    private(set) var isReady = false
    /// 0…1 across all four images — real progress, unlike Core ML compilation.
    private(set) var progress: Double = 0
    private(set) var statusMessage = "Preparing chart images…"

    /// STRONG references are the point. A weak cache would be purged under the
    /// model load and re-decoded from the 6800 px original.
    @ObservationIgnored private var decoded: [String: UIImage] = [:]
    @ObservationIgnored private var warmTask: Task<Void, Never>?

    private init() {}

    /// The prepared image, or nil if warming has not reached it yet.
    func image(_ name: String) -> Image? {
        decoded[name].map { Image(uiImage: $0) }
    }

    /// Decode all four. Idempotent and coalesced, like `TranscriptionEngine.load()`.
    func warm() async {
        if isReady { return }
        if warmTask == nil {
            warmTask = Task { await self.performWarm() }
        }
        await warmTask?.value
        if !isReady { warmTask = nil }   // allow a retry
    }

    private func performWarm() async {
        let total = Double(Self.names.count)
        var completed = 0.0

        for name in Self.names {
            statusMessage = "Preparing chart images… \(Int(completed) + 1) of \(Int(total))"

            // Off the main thread. `UIImage(named:)` is thread-safe, and
            // `preparingThumbnail(of:)` does the decode + resample on the calling
            // thread — so the transient full-size bitmap exists here, one image
            // at a time, and never on main.
            let prepared = await Task.detached(priority: .userInitiated) {
                guard let source = UIImage(named: name) else { return UIImage?.none }
                let longest = max(source.size.width, source.size.height)
                guard longest > Self.maxPixelSize else { return source }

                let scale = Self.maxPixelSize / longest
                let target = CGSize(width: (source.size.width * scale).rounded(),
                                    height: (source.size.height * scale).rounded())
                return source.preparingThumbnail(of: target) ?? source
            }.value

            if let prepared {
                decoded[name] = prepared
            } else {
                AppLog.audio.error("chart asset '\(name, privacy: .public)' missing from the bundle")
            }

            completed += 1
            progress = completed / total
        }

        statusMessage = "Chart images ready"
        isReady = true
    }
}
