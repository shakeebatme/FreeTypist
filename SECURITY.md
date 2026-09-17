# Security

## Reporting a vulnerability

Please report privately, not as a public issue.

Use GitHub's private reporting — **Security > Report a vulnerability** on
<https://github.com/shakeebatme/FreeTypist> — which opens a channel visible
only to the maintainer.

Include what you did, what happened, and the version from **Settings > General
> About**. A proof of concept helps but is not required to file.

This is a free project maintained by one person: expect a first reply within a
week rather than within a day. You will get one.

## What is in scope

FreeTypist holds unusual privileges, and these are the parts worth your time:

- **The update channel.** `appcast.xml` is fetched over HTTPS and every
  download is verified against an EdDSA public key compiled into the app. A way
  to get an unsigned or substituted build installed is the highest-severity bug
  in this project.
- **The personalization store.** Recorded text is sealed with AES-GCM under a
  key in the login Keychain. Anything that exposes plaintext, leaks the key, or
  lets another process read the database is in scope.
- **Accessibility access.** The app can read focused text and synthesize
  keystrokes. Anything that turns that into a capability for another
  application is in scope.
- **Text that should never be read.** Password fields, password-manager
  clipboard entries, and excluded apps are meant to be skipped unconditionally.
  A reproducible case where content from one of those reaches the model or the
  database is a vulnerability, not a bug.

## What is out of scope

- Builds you compile and sign yourself. Only published releases are signed
  with a Developer ID and notarized.
- Reports that the app requires Accessibility access. That is the design.
- Anything requiring an attacker to already have code execution as your user —
  at that point they can read the Keychain directly.

## Supported versions

The latest release only. There are no backports; fixes ship as a new version
through the updater.

## Disclosure

Report privately, give me a reasonable window to ship a fix through the
updater, then publish whatever you like. I will credit you in the release notes
unless you ask me not to.
