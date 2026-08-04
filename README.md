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

The cask runs a signed installer package, which lays down:

| Path | What |
|---|---|
| `/Applications/Aiherd.app` | native SwiftUI dashboard (universal) |
| `/usr/local/bin/aih` | the CLI; question-detection and search models are compiled in, and the summarizer LLM runs in-process via llama.cpp |

Then just open Aiherd.app — it launches `aih serve` itself over a Unix socket,
so no TCP port is taken. To also reach the dashboard from a phone or browser,
run `aih serve -p 8080` yourself.

Nothing else is required: no `--no-quarantine`, no `xattr` incantation, and no
trip through **System Settings → Privacy & Security**. `brew trust` above is
about letting Homebrew load a third-party tap's Ruby, not about Gatekeeper.

macOS 14 (Sonoma) or newer, on arm64 (Apple Silicon) or x86_64 (Intel).

## What runs offline

Everything except the summarizer's weights. There is **no Python involved**: the
LLM runs inside `aih` itself through llama.cpp (Metal on Apple Silicon), so the
only thing a first run fetches is the GGUF model — about 2.5 GB from Hugging
Face, into `~/Library/Application Support/aiherd/models`, and only when the
stable-terminal summarizer actually triggers. The download resumes if it is
interrupted, and the dashboard shows its progress on the pane that started it.

That feature needs Apple Silicon with ≥16 GB; elsewhere it stays off and the
rest of the app works normally.

Point it at a different model, or turn it off, with `AIHERD_SUMMARIZER`. It takes
a Hugging Face **GGUF** repo, optionally with an explicit filename — without one,
`<repo>-Q4_K_M.gguf` is assumed:

```sh
AIHERD_SUMMARIZER=off aih serve                                     # no LLM at all
AIHERD_SUMMARIZER=unsloth/Qwen3-14B-GGUF aih serve                  # bigger judge
AIHERD_SUMMARIZER=unsloth/Qwen3-14B-GGUF:Qwen3-14B-Q5_K_M.gguf aih serve
```

MLX repos (`mlx-community/...`) no longer work — that was the old Python engine.

## Signing and notarization

The installer, the app, the CLI and every bundled binary are signed with a
Developer ID certificate (team `QNHETPLPPW`) and built with the **hardened
runtime**. Both the `.pkg` and Aiherd.app carry **stapled** notarization
tickets, so Gatekeeper validates them with no network round-trip. Installer
payloads also aren't quarantined the way an archive's contents are, so the CLI
needs no unquarantining either.

Verify any of it yourself:

```sh
pkgutil --check-signature ~/Downloads/aiherd-*.pkg    # expect: signed by a developer certificate
codesign -dv --verbose=4 /Applications/Aiherd.app     # expect: flags=0x10000(runtime)
spctl -a -vvv /Applications/Aiherd.app                # expect: accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/Aiherd.app       # expect: worked
```

## Uninstall

```sh
brew uninstall --cask aiherd          # removes the app, CLI and bundled assets
brew uninstall --zap --cask aiherd    # also removes the text index and logs
```
