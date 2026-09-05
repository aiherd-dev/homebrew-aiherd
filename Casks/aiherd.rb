cask "aiherd" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.5.1"
  sha256 arm:   "cc58ef0aab865fb8b7fff134f7d35423e3ef611aa8b813b835f54366794dc3e7",
         intel: "3d0dc25ae8e3e175730db3dc0873b68921e21372693079bae3644a94cc381021"

  url "https://github.com/aiherd-dev/homebrew-aiherd/releases/download/v#{version}/aiherd-#{version}-#{arch}-apple-darwin.pkg"
  name "aiherd"
  desc "Watch terminal panes and auto-detect/auto-approve prompts"
  homepage "https://aiherd-dev.github.io/"

  depends_on macos: ">= :sonoma"

  # A signed, notarized and stapled installer laying down /Applications/
  # AIHerd.app and /usr/local/bin/aih. No Python: the summarizer LLM runs
  # in-process via llama.cpp, statically linked into `aih`.
  #
  # No postflight xattr dance: installer payloads are not quarantined the way a
  # downloaded archive's contents are, and the .pkg itself carries a stapled
  # notarization ticket, so this validates with no network at all.
  pkg "aiherd-#{version}-#{arch}-apple-darwin.pkg"

  # quit takes the app's bundle id, not the pkg id. Both: 0.4.13 and earlier
  uninstall quit:    ["dev.aiherd.AIHerd"],
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
