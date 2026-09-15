// End-to-end Tab-acceptance check against a real app.
//
// Reports four things per app: whether an editable field can be found at all,
// whether Tab accepts a word at a time, whether focus stays put, and whether the
// app feeds `AXChangeObserver` or silently leaves it on the backstop poll.
//
// Not a pure-logic test: it drives a live app with real events, so it needs
// FreeTypist running, Accessibility permission for both FreeTypist and whatever
// runs this, and the screen to itself.
//
// Usage: tab-accept-test <bundleID> [domElementID]

import AppKit
import ApplicationServices
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let bundleID = args.first else { print("usage: tab-accept-test <bundleID> [domID]"); exit(64) }
let domID = args.count > 1 ? args[1] : nil
let src = CGEventSource(stateID: .combinedSessionState)
let seed = "I will be there in a "

// MARK: - AX helpers

func str(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    var k: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &k) == .success,
          let k = k as? [AXUIElement] else { return [] }
    return k
}
func frame(of el: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
func isEditable(_ el: AXUIElement) -> Bool {
    // A password field must never be typed into, and a read-only field would
    // make the run look like an insertion failure when it is nothing of the kind.
    if str(el, kAXSubroleAttribute as String) == (kAXSecureTextFieldSubrole as String) { return false }
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success
    else { return false }
    return settable.boolValue
}

/// Widest editable text area wins: in a real window that is the document, not
/// the search box in the toolbar.
/// When a DOM id is asked for, only that element will do. Falling back to the
/// widest editable field silently tested the browser's address bar instead of
/// the page — and the omnibox's own autocomplete changes its value, so the run
/// looked like a pass.
func findField(in app: AXUIElement) -> AXUIElement? {
    var queue = [app], seen = 0
    var best: (element: AXUIElement, area: CGFloat)?
    while !queue.isEmpty, seen < 8000 {
        let el = queue.removeFirst(); seen += 1
        if let domID {
            if str(el, "AXDOMIdentifier") == domID { return el }
            queue.append(contentsOf: children(el))
            continue
        }
        let role = str(el, kAXRoleAttribute as String)
        if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String), isEditable(el) {
            let r = frame(of: el) ?? .zero
            let area = r.width * r.height
            if area > (best?.area ?? 0) { best = (el, area) }
        }
        queue.append(contentsOf: children(el))
    }
    return best?.element
}

// MARK: - Driving

func typeText(_ s: String) {
    for ch in s {
        var u = Array(String(ch).utf16)
        guard let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
        d.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        d.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}
func tapKey(_ code: CGKeyCode) {
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
}
func click(_ p: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func report(_ verdict: String, _ detail: String) -> Never {
    print("RESULT \(bundleID) \(verdict) \(detail)")
    exit(verdict == "works" ? 0 : (verdict == "skip" ? 3 : 1))
}

// MARK: - Run

guard AXIsProcessTrusted() else { report("skip", "runner lacks Accessibility permission") }
guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.freetypist.app").first != nil else {
    report("skip", "FreeTypist not running")
}
guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    report("skip", "app not running")
}
running.activate()
usleep(1_200_000)

let appEl = AXUIElementCreateApplication(running.processIdentifier)
// Chromium and Electron hosts expose only a stub tree until asked. Harmless
// everywhere else, so it is not worth detecting which is which.
//
// FreeTypist itself does NOT do this, so setting it here flatters those apps:
// the result says what FreeTypist *could* reach, not what it reaches today.
// `FT_NO_MANUAL_AX=1` measures the app as FreeTypist actually finds it.
let pokesAccessibility = ProcessInfo.processInfo.environment["FT_NO_MANUAL_AX"] == nil
if pokesAccessibility {
    AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    usleep(600_000)
}

var field: AXUIElement?
for _ in 0..<12 {
    if let found = findField(in: appEl) { field = found; break }
    usleep(400_000)
}
guard let field else {
    report("skip", domID.map { "page element #\($0) not in the AX tree" } ?? "no editable text field found")
}
let role = str(field, kAXRoleAttribute as String) ?? "?"
// Name the element that was actually driven, so a pass cannot be a pass for
// something other than what was asked for.
let identity = str(field, "AXDOMIdentifier")
    ?? str(field, kAXTitleAttribute as String)
    ?? str(field, kAXPlaceholderValueAttribute as String)
    ?? "unnamed"

guard let r = frame(of: field), r.width > 8, r.height > 8 else {
    report("skip", "field has no usable bounds (role=\(role))")
}
click(CGPoint(x: r.midX, y: r.minY + min(20, r.height / 2)))
usleep(600_000)

// Does this app feed the observer, or does it leave FreeTypist on the poll?
var notifications = 0
var observer: AXObserver?
let cb: AXObserverCallback = { _, _, _, ctx in
    ctx?.assumingMemoryBound(to: Int.self).pointee += 1
}
withUnsafeMutablePointer(to: &notifications) { counter in
    if AXObserverCreate(running.processIdentifier, cb, &observer) == .success, let observer {
        for note in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, field, note as CFString, counter)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

func value() -> String { str(field, kAXValueAttribute as String) ?? "" }
var before = value()
typeText(seed)
// Let the run loop turn so observer callbacks are actually delivered.
RunLoop.current.run(until: Date().addingTimeInterval(1.6))

// A slow app can still have been settling when we clicked, so the keystrokes
// went somewhere else. That is a race in this harness, not a fact about the
// app — Xcode failed this way once and passed on a warm retry. Try again before
// blaming the app.
if value().count <= before.count {
    click(CGPoint(x: r.midX, y: r.minY + min(20, r.height / 2)))
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    before = value()
    typeText(seed)
    RunLoop.current.run(until: Date().addingTimeInterval(1.6))
}
guard value().count > before.count else {
    report("skip", "typing did not reach the field (role=\(role))")
}

var previous = value(), accepted = 0, escaped = false
for _ in 1...4 {
    tapKey(48)
    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    let now = value()
    if now.count > previous.count { accepted += 1 }
    previous = now
    var focused: CFTypeRef?
    if AXUIElementCopyAttributeValue(
        AXUIElementCreateApplication(running.processIdentifier),
        kAXFocusedUIElementAttribute as CFString, &focused) == .success,
       let f = focused, !CFEqual(f, field) {
        escaped = true
    }
}

let feeds = notifications > 0 ? "notifies" : "POLL-ONLY"
let poked = pokesAccessibility ? "" : " raw-ax"
let detail = "role=\(role)/\(identity) tabs=\(accepted)/4 focus=\(escaped ? "ESCAPED" : "held") \(feeds)(\(notifications))\(poked)"
if accepted == 4 && !escaped { report("works", detail) }
if accepted == 0 && escaped { report("refuses", detail) }
report("partial", detail)
