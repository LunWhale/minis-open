//
//  VoiceSendGate.swift
//  Minis - chat page (AIChatView)
//
//  [T-voice-send-lock] The lock behind "Send was tapped while voice input still
//  owes text": the send button is disabled from the tap until the mic has
//  stopped, recognition has finished and the message has been handed over - and
//  for no longer. Pure: it sees attempts and counters only, so the rules are
//  unit-tested without the microphone
//  (MinisTests/Standalone/VoiceSendGateTests).
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import Foundation

/// One pending "finish recognition, then send" at a time, identified by an
/// attempt number.
///
/// Every way the wait can end goes through `conclude(_:)` with the attempt it
/// was started with. That gives the three guarantees the button needs:
/// - **at most one wait**: `begin()` refuses while one is pending, so a second
///   tap (or the Return key, or the swipe-up gesture) starts nothing;
/// - **exactly one end**: `conclude` answers true once per attempt, so the
///   message is sent once or not at all, and the lock is released once;
/// - **no ghosts**: a timer tick, a recognition result or a safety timeout that
///   belongs to an attempt which was already ended - or abandoned because the
///   user cancelled, edited the text, started recording again or left - finds a
///   different (or no) pending attempt and does nothing. It cannot send, and it
///   cannot lock the button again.
struct VoiceSendGate {
    /// How a wait ended. Only `.send` sends.
    enum End: String {
        /// Recognition finished: send what is in the transcript.
        case send
        /// A transcription failed while waiting; the retry prompt is up.
        case transcriptionFailed
        /// Recognition did not finish in time.
        case timedOut
        /// The user cancelled the transcription.
        case cancelled
        /// The user started recording again.
        case recordingRestarted
        /// The user edited, deleted or replaced the text.
        case textEdited
        /// Voice mode was left (keyboard, close) or reset.
        case voiceDismissed
        /// The chat page went away.
        case chatLeft
    }

    /// The decision of one poll tick.
    enum Verdict: Equatable {
        case keepWaiting
        case end(End)
    }

    private(set) var lastAttempt = 0
    private(set) var pending: Int?

    var isWaiting: Bool { pending != nil }

    /// Start a wait. nil when one is already pending - the caller must then
    /// do nothing at all.
    mutating func begin() -> Int? {
        guard pending == nil else { return nil }
        lastAttempt += 1
        pending = lastAttempt
        return lastAttempt
    }

    /// Whether `attempt` is the wait that is pending right now.
    func isCurrent(_ attempt: Int) -> Bool { pending == attempt }

    /// End `attempt`. True exactly once, and only for the pending attempt;
    /// false for a stale or repeated call, which must then change nothing.
    mutating func conclude(_ attempt: Int) -> Bool {
        guard pending == attempt else { return false }
        pending = nil
        return true
    }

    /// One 0.1 s poll tick of a pending wait.
    ///
    /// "Idle" (nothing queued, nothing in flight) is only trusted after a short
    /// settle and on two consecutive ticks: the segment flushed when the mic
    /// stops is delivered asynchronously. A failure wins over everything (the
    /// retry prompt owns that speech now); the time limit applies last, so a
    /// result that lands on the final tick is still sent.
    static func verdict(queuedSegments: Int, inFlight: Int, failedSinceStart: Bool,
                        elapsed: TimeInterval, timeout: TimeInterval,
                        idleTicks: inout Int) -> Verdict {
        let idle = queuedSegments == 0 && inFlight == 0
        idleTicks = (idle && elapsed >= 0.3) ? idleTicks + 1 : 0
        if failedSinceStart { return .end(.transcriptionFailed) }
        if idleTicks >= 2 { return .end(.send) }
        if elapsed >= timeout { return .end(.timedOut) }
        return .keepWaiting
    }
}
