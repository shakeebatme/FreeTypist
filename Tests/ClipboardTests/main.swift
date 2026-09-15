import AppKit

@MainActor func run() {
    var fail = 0

    func check(_ label: String, _ got: Bool, _ want: Bool) {
        guard got != want else { return }
        fail += 1
        print("FAIL \(label): want \(want), got \(got)")
    }

    // Things people copy before writing a reply. The rule this replaces —
    // "reject anything without whitespace" — threw all of the unspaced ones away.
    let allowed = [
        "Alexandra",
        "Acme Corporation",
        "https://example.com/orders/48211",
        "someone@example.com",
        "ORDER-2026-00123",
        "1Z999AA10123456784",
        "+44 20 7946 0958",
        "17 Bellevue Terrace, Edinburgh",
        "Q3 revenue was up 12% year over year.",
    ]
    for text in allowed {
        check("allow \(text.prefix(28))", ClipboardContext.looksLikeSecret(text), false)
    }

    // Credentials, which the whitespace rule let through whenever they had a
    // space in them and caught only by accident otherwise.
    let rejected = [
        "Xk9mQ2vLp1Zc",
        "hunter2Passw0rd!",
        "sk-ant-api03-abcdefghijklmnop",
        "ghp_aBcDeF1234567890",
        "xoxb-123456789012-abcdef",
        "AKIAIOSFODNN7EXAMPLE",
        "-----BEGIN RSA PRIVATE KEY-----",
    ]
    for text in rejected {
        check("reject \(text.prefix(28))", ClipboardContext.looksLikeSecret(text), true)
    }

    // Shape, not a stray character. Exempting anything containing "/" or "@"
    // let every standard-alphabet base64 blob past the entropy test.
    let base64ish = [
        "aGVsbG8vd29ybGQK+Zm9vL2Jhcmy9dGhpcw==",
        "U2VjcmV0L1Rva2VuK1ZhbHVlLzEyMzQ1Ng==",
    ]
    for text in base64ish {
        check("reject base64 \(text.prefix(20))", ClipboardContext.looksLikeSecret(text), true)
    }

    // Paths and addresses still have to survive, by looking like themselves.
    let shaped = [
        "/Users/someone/Developement/FreeTypist",
        "~/Library/Preferences/com.apple.finder.plist",
        "./scripts/test.sh",
        "https://example.com/a/b/c",
        "first.last@example.co.uk",
    ]
    for text in shaped {
        check("allow \(text.prefix(28))", ClipboardContext.looksLikeSecret(text), false)
    }

    // The email test asks a real question now.
    check("plain address is one", ClipboardContext.looksLikeEmailAddress("someone@example.com"), true)
    check("a token with an @ is not", ClipboardContext.looksLikeEmailAddress("xoxb-12@34"), false)
    check("two @ is not", ClipboardContext.looksLikeEmailAddress("a@b@example.com"), false)
    check("no domain dot is not", ClipboardContext.looksLikeEmailAddress("someone@localhost"), false)

    // A concealed pasteboard is refused whatever it holds: this is the check
    // that actually keeps password managers out.
    let board = NSPasteboard(name: NSPasteboard.Name("com.freetypist.tests"))
    board.clearContents()
    board.setString("the quarterly report is attached", forType: .string)
    board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    if ClipboardContext.current(from: board) != nil {
        fail += 1
        print("FAIL concealed pasteboard was read")
    }

    // An ordinary copy comes back, bounded.
    board.clearContents()
    board.setString("the quarterly report is attached", forType: .string)
    if ClipboardContext.current(from: board) != "the quarterly report is attached" {
        fail += 1
        print("FAIL ordinary pasteboard did not come back")
    }

    board.clearContents()
    board.setString(String(repeating: "a", count: 900), forType: .string)
    if ClipboardContext.current(from: board)?.count != 400 {
        fail += 1
        print("FAIL long pasteboard was not bounded to 400")
    }

    board.releaseGlobally()
    print(fail == 0 ? "All clipboard cases passed." : "\(fail) FAILED")
    exit(fail == 0 ? 0 : 1)
}
run()
