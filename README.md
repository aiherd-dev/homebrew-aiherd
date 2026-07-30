# homebrew-aiherd

Homebrew tap for [aiherd](https://github.com/aiherd-dev/aiherd) — a tool
that watches terminal panes and auto-detects/auto-approves prompts. The
question-detection model is embedded in the binary (no Python/uv/venv needed).

## Install

```sh
brew tap aiherd-dev/aiherd
brew trust aiherd-dev/aiherd      # required once: this is a third-party tap
brew install --cask aiherd
```

Installs the `aih` CLI and Aiherd.app. Supports macOS arm64 (Apple Silicon) and
x86_64 (Intel).

## Gatekeeper / signing

The binary is **unsigned and un-notarized**, so macOS quarantines downloaded
copies. The cask strips the quarantine flag on install, so it should just run.
If Gatekeeper still blocks it, allow it once via
**System Settings → Privacy & Security → "Open Anyway"**, or run:

```sh
xattr -dr com.apple.quarantine "$(brew --prefix)/bin/aih"
```

The permanent fix is a Developer ID signature + Apple notarization (requires a
paid Apple Developer account); not yet applied.
