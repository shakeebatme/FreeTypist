import Foundation

/// The exclusion list is a privacy promise: an app on it gets no suggestions
/// and nothing recorded. These lock in when an entry counts, and that carrying
/// old settings over never loosens anything the user switched off.

final class Counter: @unchecked Sendable { var failures = 0 }
let counter = Counter()

func check(_ label: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(label)")
    if !ok { counter.failures += 1 }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let passwordManagers = [
    "com.apple.keychainaccess", "com.apple.Passwords",
    "com.1password.1password", "com.agilebits.onepassword7",
]

// MARK: Defaults

let defaults = AppExclusions.defaults
for id in passwordManagers {
    check("\(id) excluded out of the box", defaults.excludes(id, now: now))
    check("\(id) excluded always", defaults.entries[id]?.span == .always)
}
check("defaults carry real names", defaults.entries["com.1password.1password"]?.name == "1Password")
check("the Passwords app is named", defaults.entries["com.apple.Passwords"]?.name == "Passwords")
check("defaults are all marked as offered", defaults.offeredDefaults == Set(passwordManagers))
check("an empty list excludes nothing", !AppExclusions().excludes("com.apple.mail", now: now))

// MARK: Spans

var list = AppExclusions()
list.exclude("always.app", name: "Always", span: .always)
list.exclude("timed.app", name: "Timed", span: .until(now.addingTimeInterval(60)))
list.exclude("expired.app", name: "Expired", span: .until(now.addingTimeInterval(-1)))

check("always excludes", list.excludes("always.app", now: now))
check("always still excludes far ahead", list.excludes("always.app", now: .distantFuture))
check("timed excludes before its time", list.excludes("timed.app", now: now))
check("timed stops at its time", !list.excludes("timed.app", now: now.addingTimeInterval(60)))
check("expired does not exclude", !list.excludes("expired.app", now: now))
check("unlisted does not exclude", !list.excludes("other.app", now: now))
check("no bundle identifier is never excluded", !list.excludes(nil, now: now))

// MARK: Listing

list.exclude("b.app", name: "beta", span: .always)
list.exclude("a.app", name: "Alpha", span: .always)
let names = list.active(now: now).map(\.entry.name)
check("active is sorted by name, ignoring case", names == ["Alpha", "Always", "beta", "Timed"])
check("active leaves out expired entries", !names.contains("Expired"))

// MARK: Editing

list.exclude("timed.app", name: "Timed", span: .always)
check("re-excluding replaces the span", list.entries["timed.app"]?.span == .always)

list.remove("a.app")
check("remove takes the app off", !list.excludes("a.app", now: now) && list.entries["a.app"] == nil)

check("prune reports a change", list.pruneExpired(now: now))
check("prune drops the expired entry", list.entries["expired.app"] == nil)
check("prune keeps live entries", list.entries.count == 3)
check("a second prune reports nothing", !list.pruneExpired(now: now))

// MARK: Durations

var gmt = Calendar(identifier: .gregorian)
gmt.timeZone = TimeZone(identifier: "GMT")!
let afternoon = gmt.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 15, minute: 40))!
let midnight = gmt.date(from: DateComponents(year: 2026, month: 9, day: 17))!

check("10 minutes", ExclusionDuration.tenMinutes.span(from: afternoon, calendar: gmt)
      == .until(afternoon.addingTimeInterval(600)))
check("1 hour", ExclusionDuration.oneHour.span(from: afternoon, calendar: gmt)
      == .until(afternoon.addingTimeInterval(3600)))
check("until tomorrow is the next midnight",
      ExclusionDuration.untilTomorrow.span(from: afternoon, calendar: gmt) == .until(midnight))
check("until tomorrow just after midnight is still the next midnight",
      ExclusionDuration.untilTomorrow.span(from: midnight.addingTimeInterval(1), calendar: gmt)
          == .until(midnight.addingTimeInterval(86_400)))
check("always has no end", ExclusionDuration.always.span(from: afternoon, calendar: gmt) == .always)

// MARK: Storage

if let data = try? JSONEncoder().encode(list),
   let decoded = try? JSONDecoder().decode(AppExclusions.self, from: data) {
    check("round trip keeps every entry", decoded == list)
} else {
    check("round trip encodes and decodes", false)
}

// MARK: Migration

let name: (String) -> String = { "Name of \($0)" }

let untouched = AppExclusions.migrating(excluded: nil, perAppEnabled: nil, recordingExcluded: nil, name: name)
check("never-saved old list migrates to the defaults", untouched == AppExclusions.defaults)

let migrated = AppExclusions.migrating(
    excluded: ["com.apple.keychainaccess", "blocked.app"],
    perAppEnabled: ["off.app": false, "on.app": true],
    recordingExcluded: ["unrecorded.app", "off.app"],
    name: name
)
for id in ["com.apple.keychainaccess", "blocked.app", "off.app", "unrecorded.app"] {
    check("\(id) migrates as always", migrated.entries[id]?.span == .always)
}
check("an explicit 'on' override is dropped", migrated.entries["on.app"] == nil)
check("a saved old list does not get back defaults it already had",
      migrated.entries["com.1password.1password"] == nil)
check("known apps keep their real name", migrated.entries["com.apple.keychainaccess"]?.name == "Keychain Access")
check("other apps are named by the lookup", migrated.entries["blocked.app"]?.name == "Name of blocked.app")
check("a default newer than the old list is added", migrated.entries["com.apple.Passwords"]?.span == .always)
check("nothing else sneaks in", migrated.entries.count == 5)

let cleared = AppExclusions.migrating(excluded: [], perAppEnabled: nil, recordingExcluded: nil, name: name)
check("a list the user emptied gains only what it never had",
      Set(cleared.entries.keys) == ["com.apple.Passwords"])

// MARK: Defaults added later

// A list saved before offers were tracked: the user had removed 1Password.
var early = AppExclusions.defaults
early.remove("com.apple.Passwords")
early.remove("com.1password.1password")
if let data = try? JSONEncoder().encode(early),
   var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    json["offeredDefaults"] = nil
    let stripped = try! JSONSerialization.data(withJSONObject: json)
    if var loaded = try? JSONDecoder().decode(AppExclusions.self, from: stripped) {
        check("an early list is topped up", loaded.addNewDefaults())
        check("an early list gains Passwords", loaded.excludes("com.apple.Passwords", now: now))
        check("a default removed before tracking stays removed", !loaded.excludes("com.1password.1password", now: now))
        check("topping up happens once", !loaded.addNewDefaults())
    } else {
        check("an early list decodes", false)
    }
} else {
    check("an early list encodes", false)
}

var trimmed = AppExclusions.defaults
trimmed.remove("com.apple.Passwords")
if let data = try? JSONEncoder().encode(trimmed),
   var reloaded = try? JSONDecoder().decode(AppExclusions.self, from: data) {
    check("a removed default is not brought back", !reloaded.addNewDefaults())
    check("and stays off the list", reloaded.entries["com.apple.Passwords"] == nil)
} else {
    check("a trimmed list round-trips", false)
}

print(counter.failures == 0 ? "\nAll exclusion cases passed." : "\n\(counter.failures) FAILED")
exit(counter.failures == 0 ? 0 : 1)
