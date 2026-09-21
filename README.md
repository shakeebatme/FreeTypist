# FreeTypist

Inline autocomplete for every text field on your Mac, running entirely on your
Mac.

Type in almost any app and pause for a moment. A suggestion appears as grey
text right at the cursor, in the app's own font. Press **Tab** to take it one
word at a time, or ignore it and keep typing.

Free software under the [GPL-3.0](LICENSE). Requires an Apple Silicon Mac and
macOS 14 or later.

## Highlights

- **Private by design.** Suggestions come from a small language model running on
  your Mac. Nothing you type is sent anywhere.
- **Works where you write.** Mail, Safari, TextEdit and most other apps that
  use standard macOS text fields.
- **Fixes typos as you go.** A likely misspelling is struck through, with the
  fix shown beside it; Tab accepts.
- **Learns your words, if you want it to.** Optional personalization picks up
  your names, projects and phrasing, and is stored encrypted on your Mac.
- **Stays out of the way.** Password fields are always skipped, and you choose
  which apps FreeTypist stays out of, always or for a while.

## Install

FreeTypist is currently installed from source. You need Xcode and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/shakeebatme/FreeTypist.git
cd FreeTypist
./scripts/install.sh
```

The script builds the app, installs it to `/Applications/FreeTypist.app` and
signs it. Always run that installed copy. macOS ties permissions to a specific
build, so a copy run from anywhere else may appear to have no access.

## Getting started

On first launch a short setup walks you through:

1. **Accessibility access** (required). This is how FreeTypist reads the text
   around your cursor and inserts what you accept. Grant it in
   **System Settings › Privacy & Security › Accessibility**.
2. **Screen Recording** (optional). Lets FreeTypist use what's on screen as
   context and keep the grey text readable on any background.
3. **Choosing a model.** A one-time download. FreeTypist recommends one that
   suits your Mac's memory.
4. **Personalization** (optional). Off unless you turn it on.

FreeTypist then lives in the menu bar. If suggestions don't appear, open
**Settings › Setup**: it lists anything still missing.

## Using FreeTypist

| Key | What it does |
| --- | --- |
| `Tab` | Accept the next word |
| `` ` `` (the key above Tab) | Accept the whole suggestion |
| `` ⌥↓ `` | Show another suggestion |
| `Esc` | Dismiss the suggestion, or pause briefly (your choice) |
| `` ⌃` `` | Ask for a suggestion right now |
| `` ⌃⌥⌘` `` | Exclude the current app for 10 minutes; press again to undo |

Every shortcut can be changed in **Settings › Shortcuts**, and one for
excluding all apps can be added there. Keys that aren't needed pass through as
normal: pressing `` ` `` with no suggestion showing just types a backtick.

**Other suggestions:** press `` ⌥↓ `` and the suggestion is replaced by the
next-best one, cycling back to the first at the end. The model is only asked
for the others the first time you press it, so that press takes a moment.

**Emoji:** type a colon and a name, such as `:rocket`, `:check` or `:coffee`,
and the emoji is offered inline. The name has to be complete — `:fire` works,
`:fir` does not — because a colon is ordinary punctuation and a prefix match
would fire in the middle of sentences.

### The menu bar

- **Exclude <app>:** stop suggestions in the app you're using for 10 minutes,
  an hour, until tomorrow, or always.
- **Exclude All Apps:** the same choices, for every app at once.
- **Delete What Was Recorded in <app>:** appears when personalization is on.
- **FreeTypist Settings**, **Check for Updates…** and **Quit**.

## Settings

| Pane | What you can change |
| --- | --- |
| **Setup** | A checklist of permissions and the model, with the status of each |
| **General** | Launch at login, menu bar icon, model, suggestion length, completing in the middle of a line, typo handling, update checks |
| **Context** | Use screenshots or the clipboard as extra context |
| **Personalization** | Learn from your writing, how strongly to favour your own words, and custom instructions for the model |
| **Emoji** | Suggest emoji from `:shortcodes`; allow suggestions in terminals |
| **Shortcuts** | Rebind every key, choose what Escape does, and whether accepting a word also takes the space or punctuation after it |
| **Battery** | Pause suggestions in Low Power Mode |
| **Excluded Apps** | Apps FreeTypist stays out of, always or for a set time |
| **Statistics** | Suggestions accepted, words inserted and how fast suggestions arrive, with a Reset |
| **About** | Version, model, licenses |

### Excluded Apps

FreeTypist doesn't suggest or record anything in an excluded app. Keychain
Access, Passwords and 1Password are excluded from the start.

- **To add an app,** click **+** and pick one of the apps that are running, or
  choose one from Applications.
- **To set how long,** use the menu beside each app: 10 minutes, 1 hour, until
  tomorrow, or always. Timed exclusions end on their own.
- **To remove an app,** select it and click **−** or press Delete, or
  right-click it.

## Models

Models are downloaded once from Hugging Face and stored in
`~/Library/Application Support/FreeTypist/Models`.

| Model | Download | Notes |
| --- | --- | --- |
| **Qwen 3 1.7B** | 1.0 GB | The default: fast and accurate |
| Qwen 3 4B | 2.3 GB | Larger, and about twice as slow |
| Gemma 3 1B, Gemma 3 4B | 0.75 GB, 2.3 GB | Listed under Other; weaker at this task |

These are *base* models rather than the chat-tuned versions of the same
checkpoints. Finishing a sentence you have started is what a base model does;
a chat-tuned one keeps trying to answer instead, which is where the `[topic]`
and `[Date]` placeholders came from.

Switch models any time in **Settings › General**.

## Privacy

What you type is never sent anywhere, and it isn't logged. Only two requests
leave your Mac, and neither includes anything you wrote:

- the one-time model download;
- a check for updates, which you can turn off in **Settings › General**.

Screenshots and the clipboard are only used if you turn them on. They're read
in memory and never saved. Personalization is off by default. If you turn it
on, what you write is encrypted with a key kept in your Keychain, and
**Delete All** removes the data and the key.

See [PRIVACY.md](PRIVACY.md) for exactly what is read, stored and sent.

## Good to know

- **Password fields** are always skipped, in every app.
- **Terminals** are off by default, because a suggestion accepted there becomes
  part of a command that runs. When they're switched on, suggestions appear
  only for plain-English text, such as a prompt you're typing to an AI tool,
  never for shell commands.
- **Ghostty isn't supported.** It doesn't report where the cursor is, so there
  is nowhere to show a suggestion. Terminal and iTerm2 work.
- **Some apps don't report the cursor position accurately.** In those apps, a
  suggestion appears in a small panel instead of at the cursor.
- **macOS has its own text predictions,** which can overlap FreeTypist's.
  **Settings › General** can switch them off for you.

## Uninstall

1. If you used personalization, first choose
   **Settings › Personalization › Delete All**. This also removes its
   encryption key from your Keychain.
2. Quit FreeTypist from the menu bar and delete `/Applications/FreeTypist.app`.
3. Delete `~/Library/Application Support/FreeTypist` to remove the downloaded
   models.
4. Remove FreeTypist from **System Settings › Privacy & Security** under
   Accessibility and Screen Recording.

## Contributing

Bug reports and pull requests are welcome at
[GitHub Issues](https://github.com/shakeebatme/FreeTypist/issues). Run the tests
with:

```sh
./scripts/test.sh
```

## License

FreeTypist is free software under the
**GNU General Public License v3.0**. See [LICENSE](LICENSE). You may use,
study, share and modify it. If you distribute a modified version, it must stay
under the same license, with its source available.

Copyright © 2026 Shakeeb Ahmed.

FreeTypist includes [llama.cpp](https://github.com/ggml-org/llama.cpp) and
[Sparkle](https://sparkle-project.org), both under the MIT license. Models carry
their own terms: Qwen 3 is under Apache-2.0, and Gemma 3 is under Google's
[Gemma Terms of Use](https://ai.google.dev/gemma/terms), which is not an open
source license. Details are in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

**Also see:** [PRIVACY.md](PRIVACY.md) ·
[SECURITY.md](SECURITY.md) · [docs/RELEASING.md](docs/RELEASING.md)
