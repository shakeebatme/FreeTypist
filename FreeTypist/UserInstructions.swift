import Foundation

/// The user's own style prompt, shown in Settings as "Custom AI Instructions".
enum UserInstructions {
    private static let key = "ft.instructions"

    /// Seeded from the account's full name and preferred language.
    ///
    /// Not the device name: seeding from that produces "My name is MacBook Air
    /// M5", which has to be corrected by hand. The full user name is what the
    /// user actually means.
    static var seeded: String {
        var name = NSFullUserName().trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.lowercased() == Host.current().localizedName?.lowercased() {
            name = NSUserName()
        }
        let language = Locale.current.localizedString(
            forLanguageCode: Locale.preferredLanguages.first?.prefix(2).description ?? "en"
        ) ?? "English"

        return """
        My name is \(name). I usually write in \(language).
        Write in a friendly, professional and empathetic voice. Keep your \
        sentences short, concise and readable.
        """
    }

    static var current: String {
        UserDefaults.standard.string(forKey: key) ?? seeded
    }

    static func set(_ text: String) {
        UserDefaults.standard.set(text, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
