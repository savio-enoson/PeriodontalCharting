//
//  SpeakerVerdict.swift
//  PeriodontalCharting
//
//  The buffer's three-way answer.
//
//  Two of these are the binary decision the gate has always made — "the doctor"
//  or "somebody else". The third is why the buffer exists: the gate runs 2–4 s
//  behind the microphone, so most text arrives before anything has judged it.
//
//  Collapsing to a binary forces `pending` onto one side, and both choices are
//  the bugs this is meant to fix:
//      pending -> matched      today's fail-open; unverified numbers reach a chart
//      pending -> notMatched   throws away the first seconds of every session
//

import Foundation

enum SpeakerVerdict {
    /// Nothing usable has judged this yet. HOLD — text may show, the chart waits.
    case pending
    /// The enrolled clinician. RELEASE.
    case matched
    /// Somebody else. DROP.
    case notMatched
}

extension GatedSpan {
    /// Maps the measured three-band verdict onto the buffer's decision.
    ///
    /// `accept` and `confirm` both count as the clinician — the measured rule
    /// (journal.md §9). Accept-only was tried and withheld his own dictation,
    /// because his quieter spans reach 0.730 while the other speaker's floor is
    /// 0.811.
    ///
    /// `fromFallback` overrides everything. journal.md §12: distances from blind
    /// fixed-window spans are NOT measurements — the window may be pure silence. A
    /// buffer that releases on those is a gate that opens on a coin flip.
    ///
    /// `tooShort` is unjudgeable, not verified. It passes today only because the
    /// live rule is `!= .reject`; here it waits.
    var speakerVerdict: SpeakerVerdict {
        if fromFallback { return .pending }
        switch verdict {
        case .reject:           return .notMatched
        case .accept, .confirm: return .matched
        case .tooShort:         return .pending
        }
    }
}
