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

That installs the `aih` CLI onto your `PATH` and Aiherd.app into
`/Applications`. Universal build: macOS 14+ on arm64 (Apple Silicon) and
x86_64 (Intel).

Then just open Aiherd.app — it launches `aih serve` itself over a Unix socket,
so no TCP port is taken. To also reach the dashboard from a phone or browser,
run `aih serve -p 8080` yourself.

Nothing else is required: no `--no-quarantine`, no `xattr` incantation, and no
trip through **System Settings → Privacy & Security** to approve a blocked app.
`brew trust` above is about letting Homebrew load a third-party tap's Ruby, not
about Gatekeeper.

## Signing and notarization

Both artifacts are signed with a Developer ID certificate (team `QNHETPLPPW`),
built with the **hardened runtime**, and **notarized by Apple**:

- **Aiherd.app** — notarization ticket is *stapled* into the bundle, so
  Gatekeeper validates it offline, with no network round-trip on first launch.
  The bundled `uv` helper is signed too, which notarization requires.
- **`aih`** — signed and notarized, but a bare Mach-O has nowhere to staple a
  ticket, so Gatekeeper would need an online check the first time it runs. The
  cask therefore clears the quarantine flag on the CLI at install time.

Verify any of it yourself:

```sh
codesign -dv --verbose=4 /Applications/Aiherd.app   # expect flags=0x10000(runtime)
spctl -a -vvv /Applications/Aiherd.app              # expect: accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/Aiherd.app     # expect: worked
```

If you install the CLI by hand from the release tarball rather than via the
cask, macOS may quarantine it; clear that with:

```sh
xattr -dr com.apple.quarantine ./aih
```
