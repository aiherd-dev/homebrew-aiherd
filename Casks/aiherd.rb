cask "aiherd" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.4.17"
  sha256 arm:   "4b42ed5eea4b4338abce2647f2faa2c760a1e0901e5875241ec90f873d03e842",
         intel: "2093f311d224254d95999f365ed5909390d12cb0367b914949bacb1f96fdc619"

  url "https://github.com/aiherd-dev/homebrew-aiherd/releases/download/v#{version}/aiherd-#{version}-#{arch}-apple-darwin.pkg"
  name "aiherd"
  desc "Watch terminal panes and auto-detect/auto-approve prompts"
  homepage "https://aiherd-dev.github.io/"

  depends_on macos: :sonoma

  # A signed, notarized and stapled installer laying down /Applications/
  # AIHerd.app and /usr/local/bin/aih. No Python: the summarizer LLM runs
  # in-process via llama.cpp, statically linked into `aih`.
  #
  # No postflight xattr dance: installer payloads are not quarantined the way a
  # downloaded archive's contents are, and the .pkg itself carries a stapled
  # notarization ticket, so this validates with no network at all.
  pkg "aiherd-#{version}-#{arch}-apple-darwin.pkg"

  # quit takes the app's bundle id, not the pkg id. Both: 0.4.13 and earlier
  # shipped com.elazarl.aiherd, so an upgrade from one still has to quit it.
  uninstall quit:    ["dev.aiherd.AIHerd", "com.elazarl.aiherd"],
            pkgutil: "ai.aiherd.suite",
            delete:  [
              "/Applications/AIHerd.app",
              # Pre-0.4.1 installs used this casing; keep it so an upgrade
              # removes the stale bundle instead of leaving two apps.
              "/Applications/Aiherd.app",
              "/usr/local/bin/aih",
              # Pre-0.3.1 installs staged CPython + mlx-lm wheels here.
              "/usr/local/share/aiherd",
            ]

  # The text index, settings and downloaded model weights the CLI builds at
  # runtime; `brew uninstall --zap` removes them, plain uninstall leaves them.
  zap trash: [
    "~/Library/Application Support/aiherd",
    "~/Library/Logs/aiherd-serve.log",
  ]

  caveats <<~EOS
    Just open AIHerd.app — it starts `aih serve` itself
    (over a Unix socket; no TCP port is taken). To also reach the dashboard
    from a phone/browser, run `aih serve -p 8080` yourself.

    The stable-terminal summarizer needs Apple Silicon with 16 GB or more. On
    first use it downloads the model (~2.5 GB) into
    ~/Library/Application Support/aiherd/models; the dashboard shows the
    download progress on the pane that triggered it.
  EOS
end
