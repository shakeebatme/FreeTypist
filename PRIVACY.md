# Privacy

FreeTypist is a keyboard assistant. To do its job it reads what you are typing,
and optionally what is on your screen. This document says exactly what it does
with that, and what it never does.

There is no account, no server, and no analytics. **Nothing you type is sent
anywhere.**

## The claim, and how to check it

Every network call the application makes is in one file,
[`FreeTypist/ModelRepository.swift`](FreeTypist/ModelRepository.swift), and it
does one thing: download the model you chose from Hugging Face. You can verify
that yourself in a checkout:

```sh
grep -rn "URLSession\|URL(string" FreeTypist/
```

The only other request comes from Sparkle, the update framework, and only if
you leave update checks on — see below.

## What is read

| What | When | Where it goes |
| --- | --- | --- |
| Text around your cursor | While you type in an eligible field | The local model, in memory |
| A screenshot of your displays | Only with **Use screenshots for context** on | Local OCR, in memory, discarded after the request |
| The colour behind your caret | Only with **improve appearance** on | A brightness number, to pick a legible text colour |
| Clipboard contents | Only with **Use clipboard for context** on — off by default | The local model, in memory, never stored |

Password fields are always skipped, in every app, regardless of settings. The
clipboard reader additionally ignores anything a password manager has marked as
a secret, and anything that looks like an issued token.

You can exclude any app entirely, and Keychain Access, Passwords and 1Password
are excluded out of the box.

## What is stored

Only if you turn on **Record my writing** (Personalization). Then FreeTypist
keeps a local database at:

```
~/Library/Application Support/FreeTypist/personalization.sqlite
```

Every stored phrase and term is encrypted with **AES-GCM**. The key is
generated on your Mac, kept in the login Keychain under the service
`com.freetypist.app.personalization`, and never written beside the data.
Vocabulary terms are indexed by HMAC so the database cannot be scanned for a
word without the key.

You can delete what was recorded for a single app from the menu bar, and the
whole store by deleting that file.

Downloaded models live in the same directory. They are not personal data, but
they are large — *Reveal Model Files* in the menu bar shows you where.

## What leaves your Mac

Two requests, both optional, neither containing anything you typed:

1. **The model download.** A one-time fetch from `huggingface.co` when you pick
   a model. Hugging Face will see your IP address, as any download does.
2. **The update check.** Asks
   `raw.githubusercontent.com` for a file containing the current version
   number. It sends no identifier — GitHub sees an IP address and nothing else.
   Turn it off in **Settings > General > Updates**.

That is the complete list.

## Permissions, and why each is needed

- **Accessibility** — required. It is how the app reads the text field you are
  typing in and inserts an accepted suggestion. Without it nothing works.
- **Screen Recording** — optional. Only for the two screenshot features above.
  Decline it and the rest of the app is unaffected.

Both are granted by you in System Settings and can be revoked there at any
time.

## Children

FreeTypist is not directed at children and collects nothing, from anyone.

## Changes

This file is versioned with the source. Its history is the changelog:

```sh
git log --follow PRIVACY.md
```

## Contact

Questions about any of this: open an issue at
<https://github.com/shakeebatme/FreeTypist/issues>.
