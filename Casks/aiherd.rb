cask "aiherd" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.3.0"
  sha256 arm:   "f26ac49604c063e51b1576cee1eef9d8babf886a8e5f1c92964200faa6ac6e1b",
         intel: "a5affaeb85648cc25b233e040a0de57d7f4e46b788f49fb03845aae487bd54db"

  url "https://github.com/aiherd-dev/homebrew-aiherd/releases/download/v#{version}/aiherd-#{version}-#{arch}-apple-darwin.pkg"
  name "aiherd"
  desc "Watch terminal panes and auto-detect/auto-approve prompts"
  homepage "https://github.com/aiherd-dev/aiherd"

  depends_on macos: ">= :sonoma"

  # A signed, notarized and stapled installer. It lays down /Applications/
  # Aiherd.app, /usr/local/bin/aih, and — on Apple Silicon — the bundled CPython
  # and mlx-lm wheels under /usr/local/share/aiherd, so the summarizer's first
  # run downloads only the model weights.
  #
  # No postflight xattr dance: installer payloads are not quarantined the way a
  # downloaded archive's contents are, and the .pkg itself carries a stapled
  # notarization ticket, so this validates with no network at all.
  pkg "aiherd-#{version}-#{arch}-apple-darwin.pkg"

  uninstall pkgutil: "ai.aiherd.suite",
            delete:  [
              "/Applications/Aiherd.app",
              "/usr/local/bin/aih",
              "/usr/local/share/aiherd",
            ],
            quit:    "com.elazarl.aiherd"   # the app's bundle id, not the pkg id

  # The text index and settings the CLI builds at runtime; `brew uninstall
  # --zap` removes them, plain uninstall leaves them alone.
  zap trash: [
    "~/Library/Application Support/aiherd",
    "~/Library/Logs/aiherd-serve.log",
  ]

  caveats <<~EOS
    Just open Aiherd.app — it starts `aih serve` itself
    (over a Unix socket; no TCP port is taken). To also reach the dashboard
    from a phone/browser, run `aih serve -p 8080` yourself.

    The stable-terminal summarizer needs Apple Silicon with 16 GB or more. Its
    first use downloads the model (~2 GB) from Hugging Face; everything else
    ships inside the installer.
  EOS
end
