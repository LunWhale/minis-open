//
//  NotificationCategoryCenter.swift
//  Minis
//
//  [T-user-ask] `UNUserNotificationCenter.setNotificationCategories` REPLACES
//  the whole set. Four features each registered only their own category
//  (background task, Shortcut task / keep-alive guidance, config confirm), so
//  every registration wiped the others' — harmless while none had actions,
//  fatal for user_ask, whose per-request categories carry the answer buttons.
//  Every caller now registers through here and the union is applied.
//

import UserNotifications

final class NotificationCategoryCenter {
    static let shared = NotificationCategoryCenter()

    private let lock = NSLock()
    private var categories: [String: UNNotificationCategory] = [:]

    /// Add or replace categories by identifier, then apply the full set.
    func register(_ newCategories: [UNNotificationCategory]) {
        lock.lock()
        for c in newCategories { categories[c.identifier] = c }
        let all = Set(categories.values)
        lock.unlock()
        UNUserNotificationCenter.current().setNotificationCategories(all)
    }

    /// Remove categories by identifier, then apply the full set.
    func remove(identifiers: [String]) {
        lock.lock()
        var changed = false
        for id in identifiers where categories.removeValue(forKey: id) != nil { changed = true }
        let all = Set(categories.values)
        lock.unlock()
        if changed { UNUserNotificationCenter.current().setNotificationCategories(all) }
    }

    var registeredIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return categories.keys.sorted()
    }
}
