import Foundation

func run() {
    var fail = 0
    func check(_ label: String, _ condition: Bool) {
        guard !condition else { return }
        fail += 1
        print("FAIL \(label)")
    }

    // The case this exists for, copied from a real Apple Mail reply. Every
    // mention of the recipient is surname-first, so the nearest capitalised
    // word to "Hi C" was "Hodge".
    let mail = """


        On Sep 15, 2026, at 9:53 AM, Hodge, Christine <Christine.Hodge@contractor.oakland.k12.mi.us> wrote:

        Hello,

        This is Christine from Oakland Schools, Help Me Grow. How is Arwa doing?
        """
    let hodge = Correspondent.addressed(in: mail)
    check("the given name comes out of a surname-first display name", hodge?.given == "Christine")
    check("the full name is reordered given-first", hodge?.full == "Christine Hodge")

    // Given-first display names must survive unreordered.
    let plain = Correspondent.addressed(in: "On 14 Sep 2026, Priya Raman <priya.raman@example.com> wrote:")
    check("a given-first display name is left alone", plain?.given == "Priya")
    check("a given-first full name is left alone", plain?.full == "Priya Raman")

    // No address at all: the attribution verb is the only anchor.
    let quoted = Correspondent.addressed(in: "On 14 September 2026, Priya Raman wrote:\n> Could you confirm")
    check("a name is read back from the attribution verb", quoted?.given == "Priya")
    check("the date words before it are not names", quoted?.full == "Priya Raman")

    // The date is the hazard: every word of it is capitalised too.
    check("a weekday is not mistaken for a name",
          Correspondent.addressed(in: "On Monday, Raman wrote:")?.given == "Raman")
    check("a clock time does not leak into the name",
          Correspondent.addressed(in: "On Sep 15, 2026, at 9:53 AM, Dana Okafor wrote:")?.full == "Dana Okafor")

    // A compose window with nothing quoted: the To: field is all there is, and
    // it only reaches the prompt through the screen scan.
    let compose = "To: Hodge, Christine Cc: Subject: Re: ASQ Developmental Screening"
    check("the To: field yields the given name", Correspondent.addressed(in: compose)?.given == "Christine")
    check("the header that follows it is not part of the name",
          Correspondent.addressed(in: compose)?.full == "Christine Hodge")
    check("a mid-word match is not a header",
          Correspondent.addressed(in: "Set the build to: Release") == nil)

    // From: in the window being typed in is the user. Greeting yourself by name
    // is worse than greeting nobody.
    check("the sender's own line is not read as the recipient",
          Correspondent.addressed(in: "From: Shakeeb Ahmed shakeeb.ahmed@me.com") == nil)

    // Senders with no display name. The address is trusted only when it
    // actually separates into parts.
    check("a separated local part is a name",
          Correspondent.addressed(in: "<dana.okafor@example.com> wrote:")?.full == "Dana Okafor")
    check("an unseparated local part is a guess, not a name",
          Correspondent.addressed(in: "<dokafor@example.com> wrote:") == nil)
    check("a role mailbox is nobody",
          Correspondent.addressed(in: "<no.reply@example.com> wrote:") == nil)

    // Nothing to go on.
    check("ordinary prose yields no one",
          Correspondent.addressed(in: "The Tuesday workshop runs until half past three.") == nil)
    check("an empty source yields no one", Correspondent.addressed(in: [nil, ""]) == nil)

    // Sources are tried in order: the quoted original names one person, a
    // screenshot names everyone on screen.
    let ordered = Correspondent.addressed(in: ["Priya Raman <priya.raman@example.com> wrote:", compose])
    check("the first source that answers wins", ordered?.given == "Priya")
    check("a source with nothing in it is skipped",
          Correspondent.addressed(in: ["Inbox Drafts Sent", compose])?.given == "Christine")

    // The salutation floor. "Hi " is two characters, under the model's own
    // "enough to go on" bar, and is the moment a name is most wanted.
    check("a bare opener is a greeting", Correspondent.isGreeting("Hi"))
    check("an opener with a space is a greeting", Correspondent.isGreeting("Hi "))
    check("a half-typed name is still a greeting", Correspondent.isGreeting("Hi C"))
    check("good morning opens on its second word", Correspondent.isGreeting("Good morning "))
    check("dear is a greeting", Correspondent.isGreeting("Dear "))
    check("the greeting is found on the last line",
          Correspondent.isGreeting("Subject line\nHi Chr"))
    check("a finished greeting is not still waiting",
          !Correspondent.isGreeting("Hi Christine, thanks for"))
    check("a sentence that opens with hi is not a greeting",
          !Correspondent.isGreeting("Hi there"))
    check("ordinary text is not a greeting", !Correspondent.isGreeting("Thanks for"))
    check("an empty field is not a greeting", !Correspondent.isGreeting(""))
    check("a line already ended is not a greeting", !Correspondent.isGreeting("Hi Christine,\n"))

    // The completion itself. The model cannot do this one — "Hi C" comes back
    // as "," — so it is looked up instead.
    func greeting(_ before: String, _ sources: [String?] = [mail]) -> String {
        guard let done = Correspondent.greetingCompletion(for: before, in: sources) else { return "-" }
        return done.replacing.isEmpty ? done.text : "[\(done.replacing)]\(done.text)"
    }
    check("a half-typed name is finished", greeting("Hi C") == "hristine")
    check("more of the name leaves less to finish", greeting("Hi Chris") == "tine")
    check("an empty greeting gets the whole name", greeting("Hi ") == "Christine")
    check("an opener with no space yet brings its own", greeting("Hi") == " Christine")
    check("a lowercase start is corrected rather than extended",
          greeting("Hi c") == "[c]Christine")
    check("a name that contradicts the correspondent is left alone", greeting("Hi D") == "-")
    check("a finished name is not completed again", greeting("Hi Christine") == "-")
    check("ordinary text gets no name", greeting("Thanks for") == "-")
    check("no correspondent, no completion", greeting("Hi C", ["Inbox Drafts Sent"]) == "-")
    check("the screen scan answers when nothing is quoted",
          greeting("Hi C", [nil, compose]) == "hristine")

    if fail == 0 {
        print("PASS correspondent")
    } else {
        print("\(fail) failing")
        exit(1)
    }
}

run()
