# Security policy

## Reporting a vulnerability

Please report security issues privately through a GitHub security advisory:
<https://github.com/B-PRAVEEN/CopyHistory/security/advisories/new>
(Security tab → "Report a vulnerability").

Please do not open a public issue for a vulnerability. Include the
CopyHistory version (Finder → Get Info on CopyHistory.app), your macOS
version, and steps to reproduce.

## Supported versions

Only the latest release receives security fixes.

## Scope

Of particular interest: clipboard contents or secrets reaching disk,
other apps, logs or the network; the Keychain handling of pinned secrets;
and the update check (see [PRIVACY.md](PRIVACY.md)), which must never send
anything beyond the single documented request.
