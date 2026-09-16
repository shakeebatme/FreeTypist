# Releasing FreeTypist

Two parts: a setup you do once ever, and the six steps you repeat for every
release.

Everything here assumes the machine that holds the signing key. There is only
one, and it is not in the repo.

---

## Part 1 — one-time setup

Done once for the life of the app. Skip to Part 2 if `FreeTypist/Info.plist`
already has a non-empty `SUPublicEDKey`.

### 1. Build once

Sparkle's command line tools ship inside the Swift package and are only
unpacked by a build:

```sh
./scripts/install.sh
```

### 2. Generate the signing key

```sh
./scripts/generate-update-keys.sh
```

This creates an EdDSA key pair. The private half goes into your login keychain
— macOS will ask permission, and you have to allow it. The public half is
written into `FreeTypist/Info.plist`.

That public key is what makes updates safe. It ships inside every build, and
Sparkle refuses any download not signed by the matching private key. Without
it the feed URL is just a URL anyone could impersonate.

### 3. Back up the private key

Do this now, not later:

```sh
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  -x ~/Desktop/freetypist-private-key.txt
```

Put that file somewhere you will still have it in three years — a password
manager, not the repo, and not a folder that syncs to anything public.

**Losing it is unrecoverable.** Every installed copy checks against the public
key it already has. A replacement key means every existing install rejects
every future update, forever, and the only remedy is asking each user to
download the app by hand.

### 4. Commit the public key

```sh
git add FreeTypist/Info.plist && git commit -m "Add update signing key"
```

### 5. Set up notarization

Notarization is what lets a normal user open the app by double-clicking. Without
it macOS refuses the first launch on every Mac but yours, and the only way past
is a Terminal command.

You need the **Apple Developer Program** (99 USD/year) and a **Developer ID
Application** certificate from developer.apple.com > Certificates > + >
Developer ID Application. An Apple Development certificate will not do;
notarization refuses those.

Then store credentials once:

```sh
xcrun notarytool store-credentials FreeTypist \
  --apple-id <your-apple-id> \
  --team-id <your-team-id> \
  --password <app-specific-password>
```

The password is an **app-specific password** from appleid.apple.com, not your
Apple ID password. The profile name `FreeTypist` is what the scripts look for;
override it with `FREETYPIST_NOTARY_PROFILE`.

Verify it took:

```sh
xcrun notarytool history --keychain-profile FreeTypist
```

**Do this before your first release, not after.** Changing certificates later
revokes Accessibility and Screen Recording for every existing user, makes macOS
re-prompt for the personalization key, and is the one update Sparkle is likely
to refuse. At zero users that is free; at five hundred it is a migration.

### 6. Install the GitHub CLI (optional)

Only needed for `--publish`; you can upload through the web UI instead.

```sh
brew install gh && gh auth login
```

---

## Part 2 — cutting a release

Worked example: shipping **0.3**.

### Step 1 — write the release notes

```sh
cat > /tmp/notes.html <<'EOF'
<p>Ghostty is now recognised and says why it cannot be supported.</p>
<ul>
  <li>Fixed suggestions being offered inside password fields.</li>
  <li>Faster first completion after wake.</li>
</ul>
EOF
```

**HTML, not Markdown.** Sparkle renders this inside the update window, which is
a web view. The same file is passed to GitHub for the release body, where inline
HTML renders fine.

Optional — skip `--notes` below and the appcast gets a one-line placeholder,
while GitHub generates notes from the commit log.

### Step 2 — build, sign, and stage the release

```sh
./scripts/release.sh 0.3 --notes /tmp/notes.html
```

Nothing leaves the machine. In order, it:

1. checks `SUPublicEDKey` is set and **matches the private key in your
   keychain** — a mismatch is refused here rather than shipped;
2. bumps `MARKETING_VERSION` to `0.3` and `CURRENT_PROJECT_VERSION` to the next
   integer in `project.yml`;
3. builds Release, then signs via `scripts/sign-app.sh` (Sparkle's nested
   helpers first, then the frameworks, then the bundle);
4. **notarizes the app with Apple and staples the ticket to it** — a few
   minutes, and the step that decides whether a stranger can open the download;
5. archives with `ditto` to `dist/FreeTypist-0.3.zip`, *after* stapling, so the
   archive carries the ticket;
6. signs that archive with the private key **and verifies the signature against
   it**;
7. inserts an `<item>` at the top of `appcast.xml`.

Pass `--no-notarize` to skip step 4. Without it the script refuses to build a
release when no Developer ID certificate is present, rather than quietly
producing one nobody can open.

Then it stops and prints the two commands for Step 3 and Step 4.

### Step 3 — upload the archive

The URL in the appcast is fixed by the version number, so the tag and the
filename have to match it exactly:

```
https://github.com/shakeebatme/FreeTypist/releases/download/v0.3/FreeTypist-0.3.zip
                                                           ^^^^  ^^^^^^^^^^^^^^^^^^
                                                            tag        asset name
```

With the CLI:

```sh
gh release create v0.3 dist/FreeTypist-0.3.zip \
  --repo shakeebatme/FreeTypist --title "FreeTypist 0.3" --notes-file /tmp/notes.html
```

Or through the web UI at **Releases > Draft a new release**: tag `v0.3`, attach
`dist/FreeTypist-0.3.zip`, publish.

Then confirm it is actually reachable, and that the size matches what the
appcast claims:

```sh
curl -sIL https://github.com/shakeebatme/FreeTypist/releases/download/v0.3/FreeTypist-0.3.zip \
  | grep -i '^HTTP/\|^content-length'
grep length= appcast.xml | head -1
```

### Step 4 — publish the feed

This is the step that makes the update real: installed copies poll
`appcast.xml` on `main` and act on whatever is there.

```sh
git add project.yml appcast.xml
git commit -m "Release 0.3"
git push
```

**Never push this before Step 3 has landed.** The first person to check would
be offered an update whose download 404s.

Allow a few minutes — `raw.githubusercontent.com` serves through a cache, so a
push is not visible to clients instantly.

### Step 5 — verify from a real install

Do not skip this. It is the only step that proves the update *installs*, as
opposed to merely appearing.

1. Install the **previous** version — the old DMG, or `git stash` and
   `./scripts/install.sh` from the previous tag.
2. Launch it, open the menu bar icon, choose **Check for Updates…**.
3. It should offer 0.3, download, install, and relaunch into 0.3. Confirm the
   version in **Settings > General > About**.

### Step 6 — announce, if you want

Nothing technical left. Existing installs pick it up within a day, or
immediately if the user checks by hand.

---

### Doing steps 3 and 4 in one command

Once the above is familiar:

```sh
./scripts/release.sh 0.3 --notes /tmp/notes.html --publish
```

Creates the GitHub release, commits `project.yml` and `appcast.xml`, and
pushes — in the right order. It still cannot do Step 5 for you.

---

## When something goes wrong

### Pulling a release back

Remove the `<item>` from `appcast.xml` and push. Anyone who checks afterwards
sees nothing; anyone already mid-download has a signed, valid archive, so the
worst case is they install a version you wish they had not.

```sh
git revert <the release commit>   # or edit appcast.xml by hand
git push
```

Leave the GitHub release alone unless the build itself is dangerous — deleting
it breaks the download for anyone who is mid-update.

### The script failed partway through

`project.yml` may already be bumped and `appcast.xml` already edited, while
nothing was pushed. Nothing is published until Step 3 and Step 4, so:

```sh
git checkout project.yml appcast.xml
```

and start again.

### "Signing key mismatch"

The keychain key is not the one in `Info.plist` — usually a new Mac, or a
keychain that was reset. Restore the backup from Part 1, step 3:

```sh
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  -f ~/path/to/freetypist-private-key.txt
```

If that refuses, open Keychain Access and delete any existing *Private key for
signing Sparkle updates* item first — `-f` will not overwrite one.

Do **not** generate a fresh key to make the error go away. That orphans every
existing install.

### Notarization was rejected

Apple says why, but only if you ask:

```sh
xcrun notarytool log <submission-id> --keychain-profile FreeTypist
```

The submission id is in the failing output. The usual causes are a signature
without the hardened runtime, a missing secure timestamp, or nested code signed
after the bundle that contains it — all three of which `scripts/sign-app.sh`
handles, so a rejection most often means something was signed outside it.

### An update downloads but will not install

Almost always the signing order. `scripts/sign-app.sh` signs Sparkle's four
nested executables — `Downloader.xpc`, `Installer.xpc`, `Autoupdate`,
`Updater.app` — before the framework that contains them. An app signed the
naive way passes `codesign --verify --deep --strict` and still fails to install
its own updates, so verification proves nothing here. Only Step 5 does.

---

## Three rules the whole thing rests on

1. **`CURRENT_PROJECT_VERSION` always climbs.** Sparkle compares
   `CFBundleVersion`, not the marketing version. Repeat or decrease it and the
   update is offered to nobody. `release.sh` increments it for you; do not
   hand-edit it backwards.
2. **The archive lands before the feed.** Upload, then push.
3. **The signing key never changes.** See Part 1, step 3.

---

## Gatekeeper, end to end

What a stranger downloading v0.3 actually meets: a signed, notarized, stapled
image that opens on a double-click, with no Terminal step and no "damaged"
dialog. They still grant Accessibility by hand in System Settings, because that
is a permission rather than a signature, and nothing can pre-grant it.

Check any artefact the way their Mac will:

```sh
spctl --assess --type execute --verbose=2 /Applications/FreeTypist.app
xcrun stapler validate /Applications/FreeTypist.app
```
