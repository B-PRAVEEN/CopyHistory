# Packaging

`copyhistory.rb` is a **draft** Homebrew cask for a personal tap,
`B-PRAVEEN/homebrew-tap`, which does not exist yet. Nothing here has been
published. These are the steps for when it is; none of them run automatically.

The cask installs the GitHub Release zip built by `scripts/release.sh`. That app
is ad-hoc signed and **not notarised** (no Apple Developer ID), so the cask's
`caveats` explain the first-launch approval. Homebrew's main `homebrew/cask`
repository does not accept apps that fail Gatekeeper, which is why this is a
personal tap.

## One-time: create the tap

1. On GitHub, create a public repository named exactly `homebrew-tap` under
   `B-PRAVEEN` (Homebrew maps `brew tap B-PRAVEEN/tap` to
   `github.com/B-PRAVEEN/homebrew-tap`).
2. Clone it and add the cask:

   ```sh
   git clone https://github.com/B-PRAVEEN/homebrew-tap.git
   cd homebrew-tap
   mkdir -p Casks
   cp /path/to/CopyHistory/packaging/copyhistory.rb Casks/copyhistory.rb
   ```

3. Set `version` and `sha256` as in "Per release" below, then commit and push.
4. Check it from the tap:

   ```sh
   brew tap B-PRAVEEN/tap
   brew trust B-PRAVEEN/tap   # Homebrew 7 refuses untrusted third-party taps
   brew audit --cask --strict --online B-PRAVEEN/tap/copyhistory
   brew install --cask B-PRAVEEN/tap/copyhistory
   ```

## Per release

1. Bump `VERSION` in this repo, commit, and run `scripts/release.sh`. It checks
   the tree, builds the universal zip, and prints the next commands and the sha256.
2. Push `main` first, then the tag (the workflow refuses a tag whose commit is
   not on `origin/main`):
   `git push origin main && git tag -a vX.Y.Z -m "CopyHistory X.Y.Z" && git push origin vX.Y.Z`.
   The `Release` workflow rebuilds the zip and publishes the GitHub Release with
   `CopyHistory-X.Y.Z.zip` and `CopyHistory-X.Y.Z.zip.sha256`.
3. Take the sha256 from the **published** `.sha256` asset, not from your local
   build: the CI build is a separate build, so its zip and hash can differ.

   ```sh
   gh release download vX.Y.Z --repo B-PRAVEEN/CopyHistory --pattern '*.sha256' --output -
   ```

4. In `homebrew-tap/Casks/copyhistory.rb`, set:

   ```ruby
   version "X.Y.Z"
   sha256 "<hash from step 3>"
   ```

5. Verify, then commit and push the tap:

   ```sh
   brew audit --cask --strict --online B-PRAVEEN/tap/copyhistory
   brew upgrade --cask copyhistory   # or install, on a test machine
   ```

## What has been validated

- `ruby -c packaging/copyhistory.rb`: syntax OK.
- `brew audit` / `brew style` have **not** been run against this cask. They
  need a tap, and the `--online` checks need the published release.
- The `zap` paths come from the code: `HistoryStore` keeps everything under
  `~/Library/Application Support/CopyHistory`, and settings use
  `UserDefaults.standard` (`~/Library/Preferences/io.github.b-praveen.copyhistory.plist`).
  Pinned secrets live in the login Keychain (service
  `io.github.b-praveen.copyhistory.pinned-secrets`), which `zap` cannot remove;
  the caveats say so.
