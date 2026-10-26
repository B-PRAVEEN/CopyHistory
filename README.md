# CopyHistory

A native Swift macOS menu-bar clipboard manager (SwiftPM, macOS 14+).

CopyHistory keeps a searchable history of what you copy, summoned with a global
hotkey. Clipboard text is scanned for secrets (API keys, tokens, passwords, …)
as it arrives: flagged entries are shown masked and handled as secrets
end to end. A **Paste As** transform picker (Tab) can reformat the selected
entry — e.g. curl → fetch — before pasting. Coming soon: **image OCR**
(search/recognise text in copied images) and a **Paste Stack** for pasting
several entries in sequence.

## Build and test

Requires Swift with macOS 14+ SDK. Only the Command Line Tools are installed
in this environment (no Xcode), so tests go through a wrapper script:

```sh
swift build            # debug build
./scripts/test.sh      # swift test with Swift Testing framework paths for CLT-only Macs
./scripts/make-app.sh  # release build -> build/CopyHistory.app (signed bundle, see below)
```

`./scripts/test.sh` just forwards to `swift test` with `-F`/`-rpath` flags
pointing at the Swift Testing framework shipped inside the Command Line
Tools; extra arguments are passed through (e.g. `./scripts/test.sh --filter …`).

`./scripts/make-app.sh` builds with `swift build -c release`, assembles
`build/CopyHistory.app` (binary + generated `Info.plist`, `LSUIElement`
menu-bar app, minimum system version 14.0), code-signs it, verifies the
signature, and prints the result. Pass `CH_SIGN_ID="<identity>"` for a stable
signature instead of the default ad-hoc one — see Signing below.

## Permissions

- **Accessibility** — required for auto-paste: after writing to the
  pasteboard the app synthesises ⌘V in the app that was frontmost before the
  popup appeared. Without the grant, pasting degrades to copy-only (content
  stays on the pasteboard with a "press ⌘V where you want it" hint).
- **Input Monitoring** — not needed yet; planned for the Paste Stack feature.
- **Keychain** — the app stores pinned secrets as generic-password items in
  the user's login Keychain (no access group / data-protection keychain).
  Expect a Keychain access prompt when pinned secrets are first used.

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

## Keyboard shortcuts

Global hotkey: **Shift+Cmd+V** (⇧⌘V) toggles the popup; it is configurable
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
`tccutil reset Accessibility com.example.copyhistory`.
