// Tests for [T-issue282-list-id] / [T-issue282-read-by-id] /
// [T-issue282-fetch-timeout] (OpenMinis#282).
//
// apple-reminders could only pick a list by title: `--list Work` also matched
// "Workout" when listing, two "Work" lists in different accounts could not be
// told apart, empty lists were invisible, a reminder could not be read back by
// id, and a timed-out EventKit fetch came back as ok:true with zero results.
//
//   [1] list resolution rules (port of noff_resolve_calendar_by_id_or_name)
//   [2] `lists` output shape and `list`/`read` serialization (source guards)
//   [3] timeout is an error, never an empty success (source guards)
//   [4] routing and help
//
// The EventKit calls themselves are verified on a device; this pins the
// decision logic and the wiring. Standalone: `swift RemindersListIdTests.swift`.

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

// MARK: - Port: noff_resolve_calendar_by_id_or_name

struct Cal { let id: String; let title: String; let source: String; let reminders: Bool; let writable: Bool }
enum Resolved: Equatable { case none, list(String), error(String) }

func resolve(listId: String?, listName: String?, forWrite: Bool, store: [Cal]) -> (Resolved, given: Bool) {
    let given = listId != nil || listName != nil
    if listId != nil && listName != nil { return (.error("mutually exclusive"), given) }
    if let listId {
        guard !listId.isEmpty, let cal = store.first(where: { $0.id == listId }), cal.reminders else {
            return (.error("No reminder list with id"), given)
        }
        if forWrite && !cal.writable { return (.error("read-only"), given) }
        return (.list(cal.id), given)
    }
    if let listName, forWrite {
        // noff_resolve_calendar_exact: exact, case-insensitive title.
        if let cal = store.first(where: { $0.reminders && $0.title.caseInsensitiveCompare(listName) == .orderedSame }) {
            return (.list(cal.id), given)
        }
        return (.error("No reminder list named"), given)
    }
    return (.none, given)
}

let store = [
    Cal(id: "A-work-icloud", title: "Work", source: "iCloud", reminders: true, writable: true),
    Cal(id: "B-work-exchange", title: "Work", source: "Exchange", reminders: true, writable: true),
    Cal(id: "C-workout", title: "Workout", source: "iCloud", reminders: true, writable: true),
    Cal(id: "D-shared-ro", title: "Family (shared)", source: "iCloud", reminders: true, writable: false),
    Cal(id: "E-calendar", title: "Home", source: "iCloud", reminders: false, writable: true),
]

print("▶️  1. list resolution")
check("two lists titled Work are separately selectable by id",
      resolve(listId: "A-work-icloud", listName: nil, forWrite: true, store: store).0 == .list("A-work-icloud")
      && resolve(listId: "B-work-exchange", listName: nil, forWrite: true, store: store).0 == .list("B-work-exchange"))
check("--list-id never collides Work with Workout",
      resolve(listId: "C-workout", listName: nil, forWrite: true, store: store).0 == .list("C-workout"))
check("an unknown id is an error (no default-list fallback)",
      resolve(listId: "nope", listName: nil, forWrite: true, store: store).0 == .error("No reminder list with id"))
check("an empty id is an error",
      resolve(listId: "", listName: nil, forWrite: true, store: store).0 == .error("No reminder list with id"))
check("an event calendar's id is not a reminder list",
      resolve(listId: "E-calendar", listName: nil, forWrite: false, store: store).0 == .error("No reminder list with id"))
check("--list and --list-id together are rejected",
      resolve(listId: "A-work-icloud", listName: "Work", forWrite: false, store: store).0 == .error("mutually exclusive"))
check("a read-only list can be read by id",
      resolve(listId: "D-shared-ro", listName: nil, forWrite: false, store: store).0 == .list("D-shared-ro"))
check("a read-only list cannot be a write destination",
      resolve(listId: "D-shared-ro", listName: nil, forWrite: true, store: store).0 == .error("read-only"))
check("--list <name> for a write keeps the exact-title behaviour (compat)",
      resolve(listId: nil, listName: "workout", forWrite: true, store: store).0 == .list("C-workout")
      && resolve(listId: nil, listName: "Wor", forWrite: true, store: store).0 == .error("No reminder list named"))
check("--list <name> for a read is left to the substring filter (compat)",
      resolve(listId: nil, listName: "Work", forWrite: false, store: store).0 == .none
      && resolve(listId: nil, listName: "Work", forWrite: false, store: store).given)
check("neither flag: nothing given, caller uses the default list",
      resolve(listId: nil, listName: nil, forWrite: true, store: store).0 == .none
      && !resolve(listId: nil, listName: nil, forWrite: true, store: store).given)

// MARK: - Sources

let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
let cal = read("NativeOffloads/CalendarOffload.m")
let rem = read("NativeOffloads/RemindersOffload.m")
let hdr = read("NativeOffloads/CalendarOffload.h")
func body(_ s: String, from: String, to: String) -> String {
    guard let a = s.range(of: from), let b = s.range(of: to, range: a.upperBound..<s.endIndex) else { return "" }
    return String(s[a.lowerBound..<b.lowerBound])
}
let resolver = body(cal, from: "static EKCalendar *noff_resolve_calendar_by_id_or_name(", to: "static NSMutableDictionary *reminder_to_dict(")
let serializer = body(cal, from: "static NSMutableDictionary *reminder_to_dict(", to: "static const int64_t REMINDER_FETCH_TIMEOUT_SEC")
let listsCmd = body(cal, from: "int calendar_cmd_reminder_lists(", to: "static int cmd_freebusy(")
let listCmd = body(cal, from: "int calendar_cmd_reminders(", to: "int calendar_cmd_reminder_lists(")
let byId = body(cal, from: "static EKReminder *fetch_reminder_by_id(", to: "int calendar_cmd_update_reminder(")

print("\n▶️  1b. the port matches the resolver")
check("both flags rejected first", resolver.contains("if (listId && listName) {"))
check("id resolved with calendarWithIdentifier: and checked for reminders",
      resolver.contains("[eventStore() calendarWithIdentifier:listId]") && resolver.contains("cal.allowedEntityTypes & EKEntityMaskReminder"))
check("writes need allowsContentModifications", resolver.contains("if (forWrite && !cal.allowsContentModifications) {"))
check("a name for a write goes through the exact-title resolver",
      resolver.contains("return noff_resolve_calendar_exact(listName, EKEntityTypeReminder, action, errorOut);"))
check("the resolver never returns the default list", !resolver.contains("defaultCalendarForNewReminders"))

print("\n▶️  2. output contracts")
check("every serialized reminder carries list_id and list_source",
      serializer.contains("d[@\"list_id\"] = r.calendar.calendarIdentifier") && serializer.contains("d[@\"list_source\"] = r.calendar.source.title"))
check("list uses the shared serializer", listCmd.contains("[items addObject:reminder_to_dict(r)];"))
check("lists enumerates every reminder calendar (empty ones included)",
      listsCmd.contains("[eventStore() calendarsForEntityType:EKEntityTypeReminder]"))
for key in ["id", "title", "source", "source_id", "color", "is_default", "allows_content_modifications"] {
    check("lists reports \(key)", listsCmd.contains("@\"\(key)\":"))
}
check("list --list-id selects exactly that calendar", listCmd.contains("calendars = @[byId];"))
check("list --list-id allows read-only lists (forWrite NO)",
      listCmd.contains("noff_resolve_calendar_by_id_or_name(argc, argv, @\"reminders\", NO,"))
check("create and update resolve with forWrite YES",
      cal.contains("noff_resolve_calendar_by_id_or_name(argc, argv, @\"remind\", YES,")
      && cal.contains("noff_resolve_calendar_by_id_or_name(argc, argv, @\"update\", YES,"))
check("create falls back to the default list only when no list flag was given",
      cal.contains("if (listGiven && !target) {") && cal.contains("if (!reminder.calendar) {\n        reminder.calendar = [eventStore() defaultCalendarForNewReminders];"))
check("read by id: calendarItemWithIdentifier: first, type-checked as EKReminder",
      byId.contains("[eventStore() calendarItemWithIdentifier:reminderId]") && byId.contains("isKindOfClass:[EKReminder class]"))
check("read returns the same serialization as list", byId.contains("NSMutableDictionary *data = reminder_to_dict(reminder);"))

print("\n▶️  3. fetch timeout is an error")
check("the semaphore wait result is checked", cal.contains("long waited = dispatch_semaphore_wait(sem,") && cal.contains("*timedOut = (waited != 0);"))
check("list reports a timeout instead of an empty success",
      listCmd.contains("if (timedOut) {") && listCmd.contains("reminder_fetch_timeout_error(@\"reminders\")"))
check("id lookups tell a timeout from not-found",
      cal.contains("if (timedOut) return reminder_fetch_timeout_error(action);"))
check("update, complete and delete use the timeout-aware lookup",
      ["update", "complete", "delete"].allSatisfy { cal.contains("reminder_lookup_error(@\"\($0)\", reminderId, lookupTimedOut)") })
check("no unchecked 10 s reminder waits are left",
      !cal.contains("dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));"))

print("\n▶️  4. routing and help")
check("lists and read are routed", rem.contains("isEqualToString:@\"lists\"])    return calendar_cmd_reminder_lists(")
      && rem.contains("isEqualToString:@\"read\"])     return calendar_cmd_read_reminder("))
check("header exports both", hdr.contains("int calendar_cmd_reminder_lists(") && hdr.contains("int calendar_cmd_read_reminder("))
check("help documents --list-id, lists and read, and calls --list fuzzy for list",
      rem.contains("--list-id <id>") && rem.contains("  lists       List reminder lists") && rem.contains("  read        Read one reminder by id")
      && rem.contains("substring, so \\\"Work\\\" also matches \\\"Workout\\\""))
check("unknown-command message names the new commands", rem.contains("Valid commands: list, lists, read, create, update, complete, delete."))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
