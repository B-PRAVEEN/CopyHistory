# Privacy

CopyHistory keeps your clipboard history on your Mac. It has no accounts, no
analytics, no telemetry and no crash reporting.

## What is stored, and where

- **History**: `~/Library/Application Support/CopyHistory/` (`history.json`
  plus copied images), readable only by your user account (0600 files in a
  0700 directory). Entries flagged as secrets are stored masked.
- **Pinned secrets**: the plaintext goes to your login Keychain (service
  `io.github.b-praveen.copyhistory.pinned-secrets`), never to disk in the
  history file. Unpinned flagged entries are kept in memory only.
- **Settings**: the app's standard macOS preferences (UserDefaults).

Image text recognition (OCR) runs on-device with Apple's Vision framework.

## Network

CopyHistory makes exactly one kind of network request, and only if you turn on
**Settings → Updates → Check for updates** (off by default) or press
**Check now**:

- `GET https://api.github.com/repos/B-PRAVEEN/CopyHistory/releases/latest`
- at most once a day while the setting is on, with a 10-second timeout
- headers: `Accept: application/vnd.github+json` and
  `User-Agent: CopyHistory/<version>`; macOS's networking stack also adds its
  standard `Accept-Language` / `Accept-Encoding` headers
- no cookies, no credentials, no identifiers, nothing about you or your
  clipboard; redirects are not followed

The response is only compared with the running version. If a newer release
exists, the menu bar shows "Update available" and opens the release page in
your browser when you choose it. CopyHistory never downloads or installs
anything itself. As with any web request, GitHub sees your IP address; see
GitHub's privacy statement for how it handles that.

When the setting is off, no request is made and no timer runs.
