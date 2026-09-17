import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// A key plus modifiers, addressed by *physical* key code.
///
/// The default accept key is the one above Tab — often ` or §, depending on
/// the keyboard layout. That is a position, not a character. Matching on key
/// code rather than the typed character means the same physical key works on
/// every layout.
struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: Int64
    /// Only the four modifiers a user can meaningfully bind.
    var modifiers: UInt64

    static let relevantModifiers: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl,
    ]

    init(keyCode: Int64, modifiers: CGEventFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    func matches(_ stroke: KeyStroke) -> Bool {
        stroke.keyCode == keyCode
            && stroke.flags.intersection(Self.relevantModifiers).rawValue == modifiers
    }

    // Physical key codes, layout independent.
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let grave: Int64 = 50

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    /// "⌃⌥⌘`" style label.
    var display: String {
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        return text + Self.name(for: keyCode)
    }

    static func name(for keyCode: Int64) -> String {
        switch keyCode {
        case tab: return "⇥"
        case escape: return "⎋"
        case grave: return "`"
        case 36: return "↩"
        case 49: return "space"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: break
        }
        return character(for: keyCode)?.uppercased() ?? "key \(keyCode)"
    }

    /// Resolves the character the key produces on the *current* layout, for
    /// display only.
    private static func character(for keyCode: Int64) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

/// What a bound key does.
enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case nextWord
    case fullCompletion
    case forceActivate
    case toggleCurrentApp
    case toggleGlobally

    var title: String {
        switch self {
        case .nextWord: "Complete only the next word"
        case .fullCompletion: "Trigger full completion"
        case .forceActivate: "Force-activate completions"
        case .toggleCurrentApp: "Exclude the current app for 10 minutes"
        case .toggleGlobally: "Exclude all apps"
        }
    }

    var detail: String {
        switch self {
        case .nextWord:
            "Often only a suggestion's first words are what you meant. Press this repeatedly to take them one at a time."
        case .fullCompletion:
            "Accepts the whole suggestion at once. The key above Tab works well, since it is close by and rarely typed mid-sentence."
        case .forceActivate:
            "Asks for a suggestion immediately, for the times FreeTypist cannot tell you have started typing."
        case .toggleCurrentApp:
            "Adds whichever app is in front to Excluded Apps for 10 minutes. Press again to stop excluding it."
        case .toggleGlobally:
            "Switches completions off in every app until pressed again."
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .nextWord: Shortcut(keyCode: Shortcut.tab)
        case .fullCompletion: Shortcut(keyCode: Shortcut.grave)
        case .forceActivate: Shortcut(keyCode: Shortcut.grave, modifiers: .maskControl)
        case .toggleCurrentApp:
            Shortcut(keyCode: Shortcut.grave, modifiers: [.maskControl, .maskAlternate, .maskCommand])
        case .toggleGlobally: nil
        }
    }
}

/// What Escape does *while a suggestion is showing*.
enum EscapeBehaviour: String, CaseIterable, Codable, Sendable {
    case dismiss
    case pauseBriefly

    var title: String {
        switch self {
        case .dismiss: "Dismiss the suggestion"
        case .pauseBriefly: "Pause completions for a few seconds"
        }
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    private let defaultsKey = "ft.shortcuts"
    private let defaults = UserDefaults.standard

    @Published private(set) var bindings: [ShortcutAction: Shortcut] = [:]

    init() {
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            for (raw, shortcut) in stored {
                if let action = ShortcutAction(rawValue: raw) { bindings[action] = shortcut }
            }
        } else {
            for action in ShortcutAction.allCases {
                bindings[action] = action.defaultShortcut
            }
        }
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? { bindings[action] }

    func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
        bindings[action] = shortcut
        persist()
    }

    func resetToDefaults() {
        for action in ShortcutAction.allCases { bindings[action] = action.defaultShortcut }
        persist()
    }

    /// First action bound to this keystroke, if any.
    func action(for stroke: KeyStroke) -> ShortcutAction? {
        ShortcutAction.allCases.first { bindings[$0]?.matches(stroke) == true }
    }

    private func persist() {
        var encodable: [String: Shortcut] = [:]
        for (action, shortcut) in bindings { encodable[action.rawValue] = shortcut }
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
