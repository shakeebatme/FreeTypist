import Foundation

/// Works out who the message being written is addressed to, and what to call
/// them.
///
/// Exists because of one repeatable wrong answer. In Apple Mail every trace of
/// the recipient is surname-first: the To: token reads "Hodge, Christine", and
/// so does the attribution line above the quoted reply. The capitalised name
/// nearest a half-typed "Hi C" is therefore the *surname*, and that is what the
/// model completed. Widening any context budget makes it worse, not better —
/// more of that screen is more of "Hodge, Christine". The prompt has to say
/// which half is the given name, which means something has to work it out.
///
/// These are parsing rules with their own failure mode — the wrong name in a
/// greeting is worse than no name at all — so they live apart from
/// `CompletionPrompt` and are tested as such. See `Tests/CorrespondentTests`.
enum Correspondent {

    /// A person the message is addressed to.
    struct Name: Equatable {
        /// What to greet them by.
        let given: String
        /// Given name first, whatever order the source wrote it in.
        let full: String
    }

    // MARK: - Who

    /// The first name any source yields, in the order given.
    ///
    /// Callers pass the quoted original ahead of the screen scan: an
    /// attribution line names one person, and a screenshot names everyone who
    /// happens to be on screen.
    static func addressed(in sources: [String?]) -> Name? {
        for source in sources.compactMap({ $0 }) {
            if let name = addressed(in: source) { return name }
        }
        return nil
    }

    static func addressed(in text: String) -> Name? {
        fromAddress(text) ?? fromAttribution(text) ?? fromRecipientField(text)
    }

    // MARK: - When it matters

    private static let openers: Set<String> = [
        "hi", "hey", "hello", "dear", "morning", "afternoon", "evening",
    ]

    /// An opening salutation with the name not yet written.
    private struct Greeting {
        /// How much of the name has been typed — empty while the opener is
        /// still the last word.
        let typed: String
        /// Whether a space already separates the opener from the name.
        let spaced: Bool
    }

    private static func greeting(_ before: String) -> Greeting? {
        let line = before.components(separatedBy: .newlines).last ?? before
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        // "Good morning" opens on its second word.
        if words.first?.lowercased() == "good" { words.removeFirst() }
        guard let opener = words.first, openers.contains(opener.lowercased()) else { return nil }
        let spaced = line.last?.isWhitespace == true
        switch words.count {
        case 1:
            return Greeting(typed: "", spaced: spaced)
        case 2:
            // A partial name, not a sentence that happens to open "Hi there" —
            // and not a name already finished with a space after it.
            let typed = words[1]
            guard !spaced, typed.allSatisfy(\.isLetter),
                  !collectives.contains(typed.lowercased()) else { return nil }
            return Greeting(typed: typed, spaced: true)
        default:
            return nil
        }
    }

    /// True when the caret sits in an opening salutation still waiting for a
    /// name — "Hi", "Hi C", "Good morning ".
    ///
    /// The coordinator needs this because its "enough to go on" floor is three
    /// characters and "Hi " is two, so the one moment a name is most obviously
    /// wanted was the one moment the model was never asked for it.
    static func isGreeting(_ before: String) -> Bool { greeting(before) != nil }

    /// What to insert when the caret sits in a greeting and the correspondent
    /// can be named.
    ///
    /// Deterministic on purpose: this is the one completion the model cannot
    /// do. Measured against Qwen3-1.7B on a prompt that named Christine three
    /// times over — asked to finish "Hi C" it read the C as an initial and
    /// answered ","; asked to finish "Hi " it wrote a whole opening paragraph.
    /// Nothing here needs predicting. The name is in the quoted original.
    ///
    /// The greeting is tested before the sources are searched, so the scan of a
    /// whole quoted thread does not run on keystrokes that cannot use it.
    ///
    /// - Returns: the continuation to insert and the partial word it stands in
    ///   for, or nil when this is not a greeting waiting for a name, nobody is
    ///   named, or what is typed already contradicts the name.
    static func greetingCompletion(
        for before: String,
        in sources: [String?]
    ) -> (text: String, replacing: String)? {
        guard let greeting = greeting(before), let name = addressed(in: sources) else { return nil }
        guard greeting.typed.count < name.given.count,
              name.given.lowercased().hasPrefix(greeting.typed.lowercased()) else { return nil }

        guard !greeting.typed.isEmpty else {
            // Nothing typed to build on, so the space is ours to add.
            return (greeting.spaced ? name.given : " " + name.given, "")
        }
        // Standing in for what is already typed only when the case disagrees:
        // "Hi c" wants correcting, "Hi C" only wants finishing, and the overlay
        // shows a correction differently from a completion.
        guard name.given.hasPrefix(greeting.typed) else { return (name.given, greeting.typed) }
        return (String(name.given.dropFirst(greeting.typed.count)), "")
    }

    /// What follows an opener when no name is coming. "Hi there" is a greeting;
    /// it is not a greeting waiting for a name.
    private static let collectives: Set<String> = [
        "there", "all", "everyone", "everybody", "team", "folks", "guys",
        "again", "and", "hi", "hey", "hello",
    ]

    // MARK: - Sources

    /// `Display Name <local@domain>` — the shape of a mail attribution line,
    /// and the most reliable source there is, because the display name and the
    /// address agree about who this is.
    private static func fromAddress(_ text: String) -> Name? {
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "<") {
            index = text.index(after: open)
            guard let close = text[index...].firstIndex(of: ">") else { break }
            let address = text[index..<close]
            index = text.index(after: close)
            guard address.contains("@"), !address.contains(where: \.isWhitespace) else { continue }
            if let display = name(from: trailingWords(in: text[..<open])) { return display }
            if let derived = name(fromAddress: address) { return derived }
        }
        return nil
    }

    /// `… Priya Raman wrote:` — the other attribution shape, for clients that
    /// quote without carrying the address.
    private static func fromAttribution(_ text: String) -> Name? {
        var search = text.startIndex
        while let found = text.range(of: "wrote:", options: .caseInsensitive, range: search..<text.endIndex) {
            search = found.upperBound
            if let name = name(from: trailingWords(in: text[..<found.lowerBound])) { return name }
        }
        return nil
    }

    /// The recipient line of a compose window, which the screen scan can read
    /// when there is no quoted message to read — a first email to someone names
    /// them nowhere else.
    ///
    /// `To:` only, never `From:`. In the window being typed in, `From:` is the
    /// user, and greeting yourself by name is a worse failure than greeting
    /// nobody.
    private static func fromRecipientField(_ text: String) -> Name? {
        var search = text.startIndex
        // Case-sensitive, and a word of its own. A header is rendered "To:";
        // "…set the build to: Release" is a sentence, and a lowercase match
        // would hand a greeting the word "Release".
        while let found = text.range(of: "To:", range: search..<text.endIndex) {
            search = found.upperBound
            if found.lowerBound > text.startIndex {
                let previous = text[text.index(before: found.lowerBound)]
                guard previous.isWhitespace else { continue }
            }
            if let name = name(from: leadingWords(in: text[found.upperBound...])) { return name }
        }
        return nil
    }

    // MARK: - Assembling a name

    private struct Word {
        let text: String
        /// Whether a comma came with it. In "Hodge, Christine" that comma is
        /// the entire ordering signal.
        let comma: Bool
    }

    /// Turns the words of a display name into a `Name`.
    ///
    /// The comma is the only ordering signal worth trusting: "Hodge, Christine"
    /// is surname-first by convention, "Christine Hodge" is not, and nothing
    /// about the two words themselves tells them apart.
    private static func name(from words: [Word]) -> Name? {
        guard let first = words.first else { return nil }
        guard words.count > 1 else { return Name(given: first.text, full: first.text) }
        guard first.comma else {
            return Name(given: first.text, full: words.map(\.text).joined(separator: " "))
        }
        let given = words[1].text
        let surnames = [first.text] + words.dropFirst(2).map(\.text)
        return Name(given: given, full: ([given] + surnames).joined(separator: " "))
    }

    /// A name from the address itself, for senders who send without a display
    /// name. Trusted only when the local part actually separates into parts:
    /// "christine.hodge" is a name, "chodge" is a guess.
    private static func name(fromAddress address: Substring) -> Name? {
        let local = String(address.prefix(while: { $0 != "@" }))
        let parts: [String] = local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" || $0 == "+" })
            .map(String.init)
            .filter { $0.count >= 2 && $0.allSatisfy(\.isLetter) }
        // Checked whole as well as by part: "no.reply" is "noreply" with a dot
        // in it, and its first part is not a given name.
        guard parts.count >= 2,
              !roles.contains(parts.joined().lowercased()),
              !roles.contains(parts[0].lowercased()) else { return nil }
        return name(from: parts.prefix(3).map { Word(text: capitalised($0), comma: false) })
    }

    private static func capitalised(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst().lowercased()
    }

    // MARK: - Reading name words out of running text

    /// The run of name-shaped words at the end of `text`, in reading order.
    ///
    /// Bounded, and stopping at the first word that is not name-shaped, because
    /// what precedes an address is a whole attribution line — "On Sep 15, 2026,
    /// at 9:53 AM, Hodge, Christine" — and everything up to "AM," has to be
    /// left behind.
    private static func trailingWords(in text: Substring, limit: Int = 4) -> [Word] {
        var words: [Word] = []
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            guard words.count < limit, let word = nameWord(token) else { break }
            words.append(word)
        }
        return words.reversed()
    }

    private static func leadingWords(in text: Substring, limit: Int = 4) -> [Word] {
        var words: [Word] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            guard words.count < limit, let word = nameWord(token) else { break }
            words.append(word)
        }
        return words
    }

    /// Strips the punctuation a name picks up in running text, and reports
    /// whether a comma came off the end.
    private static func nameWord(_ token: Substring) -> Word? {
        var text = token
        while let first = text.first, "\"'(<[".contains(first) { text = text.dropFirst() }
        var comma = false
        while let last = text.last, "\"')>],;:.".contains(last) {
            if last == "," { comma = true }
            text = text.dropLast()
        }
        guard text.count >= 2, text.count <= 20 else { return nil }
        guard text.first?.isUppercase == true else { return nil }
        // "AM", "GMT", "IT" are capitalised and are not people.
        guard text.dropFirst().contains(where: \.isLowercase) else { return nil }
        guard text.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return nil }
        guard !notNames.contains(text.lowercased()) else { return nil }
        return Word(text: String(text), comma: comma)
    }

    /// Capitalised words that turn up next to a name in exactly the places this
    /// looks, and are not one.
    private static let notNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "on", "at", "in", "from", "to", "cc", "bcc", "sent", "subject", "date",
        "re", "fwd", "fw", "wrote", "said", "the", "and", "dear", "hi", "hello", "hey",
        "am", "pm", "reply", "forwarded", "message", "original",
    ]

    /// Mailbox names that belong to a function rather than a person.
    private static let roles: Set<String> = [
        "info", "support", "help", "helpdesk", "admin", "contact", "sales",
        "team", "office", "noreply", "donotreply", "mail", "mailer", "postmaster",
        "notifications", "billing", "accounts", "service", "marketing", "news",
        "hello", "hi", "enquiries", "inquiries", "careers", "jobs", "press",
    ]
}
