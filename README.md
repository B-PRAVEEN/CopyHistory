# CopyHistory

A native Swift macOS menu-bar clipboard manager (SwiftPM, macOS 14+).

CopyHistory keeps a searchable history of what you copy, summoned with a global
hotkey. Clipboard text is scanned for secrets (API keys, tokens, passwords, …)
as it arrives: flagged entries are shown masked and handled as secrets
end to end. A **Paste As** transform picker (Tab) can reformat the selected
entry — e.g. curl → fetch — before pasting. Coming soon: **image OCR**
(search/recognise text in copied images) and a **Paste Stack** for pasting
several entries in sequence.

Source: <https://github.com/B-PRAVEEN/CopyHistory>

## Install

Requires macOS 14 Sonoma or later; the build is universal (Apple Silicon and Intel).

**GitHub Releases (primary).** Download `CopyHistory-X.Y.Z.zip` and
`CopyHistory-X.Y.Z.zip.sha256` from
<https://github.com/B-PRAVEEN/CopyHistory/releases>, check the zip, unzip it, and
move `CopyHistory.app` to `/Applications`:

```sh
cd ~/Downloads
shasum -a 256 -c CopyHistory-X.Y.Z.zip.sha256   # must print "CopyHistory-X.Y.Z.zip: OK"
```

Safari unzips downloads by default and discards the `.zip`, so to verify,
fetch both files with curl instead:

```sh
V=X.Y.Z
curl -LO "https://github.com/B-PRAVEEN/CopyHistory/releases/download/v$V/CopyHistory-$V.zip"
curl -LO "https://github.com/B-PRAVEEN/CopyHistory/releases/download/v$V/CopyHistory-$V.zip.sha256"
shasum -a 256 -c "CopyHistory-$V.zip.sha256" && ditto -x -k "CopyHistory-$V.zip" .
```

**Homebrew** (from the [`B-PRAVEEN/homebrew-tap`](https://github.com/B-PRAVEEN/homebrew-tap) tap):

```sh
brew tap B-PRAVEEN/tap
brew trust B-PRAVEEN/tap   # Homebrew 7 only loads casks from third-party taps you trust
brew install --cask copyhistory
```

**First launch: the app is not notarised.** CopyHistory is ad-hoc signed and
has not been notarised by Apple (there is no Apple Developer ID behind it), so
macOS blocks the first launch with a warning that it cannot check the app for
malicious software. Approve it once:

- **macOS 15 Sequoia and later:** open the app and dismiss the warning, then go
  to System Settings → Privacy & Security, scroll to Security, and click
  **Open Anyway** for CopyHistory (confirm with your password).
- **macOS 14 Sonoma:** Control-click (right-click) `CopyHistory.app` in
  Applications, choose **Open**, then **Open** again in the dialog.

Then grant **Accessibility** (System Settings → Privacy & Security →
Accessibility) so it can auto-paste; see [Permissions](#permissions). Because
the signature is ad-hoc, each new version is a new signature to macOS: after
upgrading, re-grant Accessibility even if the toggle still looks on (see
[Signing](#signing)).

## Build and test

Requires Swift with macOS 14+ SDK. Only the Command Line Tools are installed
in this environment (no Xcode), so tests go through a wrapper script:

```sh
swift build            # debug build
./scripts/test.sh      # swift test with Swift Testing framework paths for CLT-only Macs
./scripts/make-app.sh  # release build -> build/CopyHistory.app (signed bundle, see below)
./scripts/release.sh --dry-run  # universal release zip + .sha256 in build/ (see Releasing)
```

`./scripts/test.sh` just forwards to `swift test` with `-F`/`-rpath` flags
pointing at the Swift Testing framework shipped inside the Command Line
Tools; extra arguments are passed through (e.g. `./scripts/test.sh --filter …`).

`./scripts/make-app.sh` builds with `swift build -c release`, assembles
`build/CopyHistory.app` (binary + generated `Info.plist`, bundle ID
`io.github.b-praveen.copyhistory`, `LSUIElement` menu-bar app, minimum system
version 14.0), code-signs it, verifies the signature, and prints the result.
The app version (`CFBundleShortVersionString`) comes from the `VERSION` file
(one line, `X.Y.Z`); bump it there only. Pass `CH_SIGN_ID="<identity>"` for a stable
signature instead of the default ad-hoc one — see Signing below.

## Permissions

- **Accessibility** — required for auto-paste: after writing to the
  pasteboard the app synthesises ⌘V in the app that was frontmost before the
  popup appeared. Without the grant, pasting degrades to copy-only (content
  stays on the pasteboard with a "press ⌘V where you want it" hint).
- **Input Monitoring** — needed only for Paste Stack: a listen-only monitor sees
  your ⌘V presses so the next item can be queued. Without it, Paste Stack still
  works through its fallback shortcut ⌥⌘V (some apps use that shortcut themselves).
- **Keychain** — the app stores pinned secrets as generic-password items in
  the user's login Keychain (no access group / data-protection keychain).
  Expect a Keychain access prompt when pinned secrets are first used.

**Upgrading from a build with the old bundle ID (`com.example.copyhistory`):**
macOS treats the renamed app as a new app. Accessibility and Input Monitoring
grants do not carry over (grant them again; remove the stale entry with
`tccutil reset Accessibility com.example.copyhistory`), and pinned secrets
stored in the Keychain under the old service
(`com.example.copyhistory.pinned-secrets`) are not read by the new build:
those pinned entries show only their masked placeholder. Copy anything you
need out of them with the old build before upgrading; the old Keychain items
can then be deleted in Keychain Access.

## Security design

- Flagged secrets live **in memory only** unless pinned: an unpinned flagged
  entry is never written to disk and is lost on quit.
- `history.json` (`~/Library/Application Support/CopyHistory/history.json`)
  holds **masked text** for flagged entries, so secrets never touch the file
  in plaintext. Search also matches against masked text only.
- History and image files are created with **0600** permissions inside a
  **0700** directory.
- Pinning a flagged entry writes only a masked placeholder to `history.json`;
  the plaintext goes to the **login Keychain** and is restored from there on
  launch (off the main thread).
- Secret pasteboard writes carry **Concealed/Transient markers**
  (`org.nspasteboard.ConcealedType`) so other clipboard managers skip them,
  are kept off Universal Clipboard (`currentHostOnly`), and **auto-clear**:
  2 seconds after an auto-paste, 30 seconds after copy-only — and only if the
  user hasn't copied something else since.

## Privacy

CopyHistory has no accounts, analytics or telemetry; your history stays on
your Mac. The **only network request the app ever makes** is the optional
update check, which is **off by default** (Settings → Updates). When on, it
asks GitHub at most once a day for the latest release
(`GET https://api.github.com/repos/B-PRAVEEN/CopyHistory/releases/latest`,
no cookies, no identifiers beyond `User-Agent: CopyHistory/<version>`, nothing
about you or your clipboard). **Check now** runs the same request on demand.
If a newer version exists, the menu bar shows "Update available: vX.Y.Z",
which opens the release page in your browser; update with
`brew upgrade --cask copyhistory`. The app never downloads or installs
anything itself. Details: [PRIVACY.md](PRIVACY.md). To report a security
issue, see [SECURITY.md](SECURITY.md).

## Keyboard shortcuts

Global hotkey: **Option+V** (⌥V) toggles the popup; it is configurable
in Settings (a replacement must include Command or Control).

Inside the popup:

| Keys | Action |
| --- | --- |
| ↑ / ↓ | Move selection (in list or transform picker) |
| Return | Paste selected entry |
| Shift+Return | Paste with the plain-text default flipped |
| Option+Return | Copy only (no auto-paste) |
| Tab | Open/close the Paste As transform picker |
| Return (in picker) | Apply transform and paste |
| Tab / Esc (in picker) | Back to the list |
| Esc (in list) | Close the popup |
| Cmd+1 … Cmd+9 | Paste the nth entry directly |
| Opt+Cmd+1 … 9 | Paste nth entry, plain-text default flipped |
| Cmd+P | Pin / unpin selected entry |
| Cmd+Delete | Delete selected entry |

Clicking an entry pastes it; Option-click flips the plain-text default for
that paste. The footer toggle sets the plain-text default (images are skipped
when plain-text-only paste applies). The footer shows the essentials:
`↩ paste   ⌥↩ copy   ⇥ transform   ⌘P pin   ⌘⌫ delete`.

## Signing

`make-app.sh` signs ad-hoc (`codesign --sign -`) by default. An ad-hoc
signature embeds a cdhash-only designated requirement, and macOS TCC keys the
Accessibility (and Keychain) grant to it — so **every rebuild invalidates the
previous grant**: System Settings may still show the toggle as on, but
`AXIsProcessTrusted()` returns false and the app degrades to copy-only until
access is re-granted. To keep grants across rebuilds, create a self-signed
code-signing certificate in Keychain Access and build with:

```sh
CH_SIGN_ID="Your Name" scripts/make-app.sh
```

A self-signed identity is stable on this Mac only; other machines still see
an untrusted signature. Fully stable distribution needs a paid Apple
Developer ID certificate. To clear a stale grant:
`tccutil reset Accessibility io.github.b-praveen.copyhistory`.

## Releasing

`scripts/release.sh` builds arm64 and x86_64 release binaries separately,
merges them with `lipo`, assembles the app through `make-app.sh`
(`CH_BIN=<universal binary>`), signs it ad-hoc, verifies it (`lipo -archs`,
`codesign --verify --deep --strict`, `plutil -lint`), and writes
`build/CopyHistory-X.Y.Z.zip` plus its `.sha256`. It refuses to run unless the
tree is clean, you are on `main`, and tag `vX.Y.Z` (from `VERSION`) does not
exist yet; `--dry-run` skips the clean-tree check for local trials. It never
tags or pushes; it prints the `git push` / `git tag` commands instead. Push
`main` first, then the tag: the workflow refuses a tag whose commit is not on
`origin/main`. Pushing the tag runs `.github/workflows/release.yml`, which tests, rebuilds with
`release.sh --ci`, and publishes the GitHub Release. Homebrew tap steps:
[packaging/README.md](packaging/README.md).

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 B Praveen.
