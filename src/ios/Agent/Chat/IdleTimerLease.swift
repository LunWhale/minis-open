//
//  IdleTimerLease.swift
//  MinisApp
//
//  [T-idle-timer-lease] The single writer of UIApplication.isIdleTimerDisabled.
//
//  Several features want the screen to stay on: Keep Screen Awake during agent
//  tasks, the backup's "keep screen awake", the iCloud migration sheet while it
//  has pending pushes, the DEBUG menu item, and Always On mode. Each used to
//  write the flag directly, so they undid each other: the migration sheet wrote
//  `false` whenever it had no work, turning off a lock Keep Screen Awake was
//  holding; the end of a backup cleared the flag when it was on for any reason;
//  and the backup toggle read the flag back, so it showed ON while a chat task
//  was the one holding it.
//
//  Now each feature holds a lease under its own owner, and the flag is on while
//  any lease is held. Releasing one owner never affects another.
//

import UIKit

@MainActor
enum IdleTimerLease {
    /// Who wants the screen on. One case per feature; a feature only ever
    /// sets its own.
    enum Owner: String, CaseIterable {
        case keepScreenAwake
        case alwaysOn
        case backup
        case syncMigration
        case debugMenu
    }

    private static let logger = AppLogger(category: "IdleTimerLease")

    /// Owners currently holding the screen on.
    private(set) static var holders: Set<Owner> = []

    /// Take (`held == true`) or give back this owner's lease. Idempotent.
    static func set(_ owner: Owner, held: Bool, reason: String = "") {
        let changed = held ? holders.insert(owner).inserted : holders.remove(owner) != nil
        if changed {
            logger.info("[IdleTimerLease] \(owner.rawValue) \(held ? "acquired" : "released")\(reason.isEmpty ? "" : " reason=\(reason)") holders=\(holders.map(\.rawValue).sorted())")
        }
        apply()
    }

    static func isHeld(_ owner: Owner) -> Bool { holders.contains(owner) }

    static var isAnyHeld: Bool { !holders.isEmpty }

    /// Write the flag again from the lease set. iOS may reset it while the app
    /// is in the background, so this runs on every return to the foreground
    /// (deferred off the notification, see KeepScreenAwakeController).
    static func reapply() {
        apply()
    }

    /// Compares with the live system value, not a cached one, so a reset done
    /// by the system is corrected on the next call.
    private static func apply() {
        let want = !holders.isEmpty
        guard UIApplication.shared.isIdleTimerDisabled != want else { return }
        UIApplication.shared.isIdleTimerDisabled = want
        logger.info("[IdleTimerLease] isIdleTimerDisabled=\(want)")
    }
}
