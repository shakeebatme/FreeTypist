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

### 5. Install the GitHub CLI (optional)

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
4. archives with `ditto` to `dist/FreeTypist-0.3.zip`;
5. signs that archive with the private key **and verifies the signature against
   it**;
6. inserts an `<item>` at the top of `appcast.xml`.

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

## Still ahead: notarization

Releases today are signed with an Apple Development certificate and are not
notarized, so a *first* install still needs
`xattr -dr com.apple.quarantine /Applications/FreeTypist.app`. Updates
installed by Sparkle do not.

Moving to a Developer ID certificate is the one update Sparkle is likely to
refuse outright — it compares the incoming bundle's signing identity against
the running app's — on top of revoking Accessibility and Screen Recording and
putting the personalization key at risk. See **Distribution and notarization**
in the README before attempting it, and test that specific transition with a
throwaway release first.
