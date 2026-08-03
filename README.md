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

Both the `aih` CLI and Aiherd.app are signed with a Developer ID certificate
(team `QNHETPLPPW`), built with the hardened runtime, and notarized by Apple.
Aiherd.app has its notarization ticket **stapled**, so it validates offline.

A bare executable cannot carry a stapled ticket, so the cask strips the
quarantine flag from `aih` on install to avoid an online Gatekeeper check on
first run. If you install the CLI by hand instead and macOS blocks it:

```sh
xattr -dr com.apple.quarantine "$(brew --prefix)/bin/aih"
```
