//
//  SpeakerVerdict.swift
//  PeriodontalCharting
//
//  DEPRECATED 2026-08-13 — ENTIRE FILE. Safe to delete.
//
//  This was the three-way answer for a TEXT buffer: the ASR emitted timestamped
//  segments, the gate ran 2–4 s behind the microphone, and most text arrived
//  before anything had judged it — so `pending` existed to hold text off the
//  chart while a verdict caught up.
//
//  Wav2Vec removed the problem rather than solving it. Gating now happens on
//  AUDIO, before the decoder ever sees it: `SpeakerGateService.gatedAudio` judges
//  a chunk and returns the buffer in the same call, so by the time text exists it
//  has already been gated. There is no window in which text is unjudged, hence no
//  `pending` state to represent.
//
//  Nothing referenced this file when it was deprecated. `GatedSpan.fromFallback`,
//  its only remaining input, went with the timeline in SpeakerGateService.
//
//  import Foundation
//
//  enum SpeakerVerdict {
//      // Nothing usable has judged this yet. HOLD — text may show, the chart waits.
//      case pending
//      // The enrolled clinician. RELEASE.
//      case matched
//      // Somebody else. DROP.
//      case notMatched
//  }
//
//  extension GatedSpan {
//      // Maps the measured three-band verdict onto the buffer's decision.
//      //
//      // `accept` and `confirm` both count as the clinician — the measured rule
//      // (journal.md §9). Accept-only was tried and withheld his own dictation,
//      // because his quieter spans reach 0.730 while the other speaker's floor is
//      // 0.811. That rule SURVIVES, in `GatedSpan.passesGate`.
//      //
//      // `fromFallback` overrode everything: journal.md §12, distances from blind
//      // fixed-window spans are NOT measurements — the window may be pure silence.
//      // That rule survives too, as `rescueSpans` refusing to emit blind windows
//      // on the live path at all.
//      var speakerVerdict: SpeakerVerdict {
//          if fromFallback { return .pending }
//          switch verdict {
//          case .reject:           return .notMatched
//          case .accept, .confirm: return .matched
//          case .tooShort:         return .pending
//          }
//      }
//  }
//
