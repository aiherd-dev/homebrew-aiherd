cask "aiherd" do
  # Not the `arch` stanza: it follows the arch of the *brew* evaluating this
  # cask (Hardware::CPU.type, i.e. hw.cputype, which Rosetta translates too),
  # so an Intel /usr/local brew on an M-series Mac asked for the x86_64 pkg —
  # whose `aih` then turns the summarizer off on hardware that qualifies.
  # hw.optional.arm64 is the machine, not the process: Homebrew reads it for
  # exactly this reason and it survives Rosetta. Absent on a real Intel Mac,
  # which `sysctl_bool!` reads as false rather than raising.
  native_arm = Hardware::CPU.physical_cpu_arm64?
  arch = native_arm ? "aarch64" : "x86_64"

  version "0.5.23"
  shas = {
    arm:   "e0496373255d330e58984ba2abe0f4661b3edc8084a60e49e7ac5668ae8d7a6a",
    intel: "b7d39519e0904dae143bed88a40fa385005eeb0feb35fbc6701bd42240dc78b4",
  }
  sha256 native_arm ? shas[:arm] : shas[:intel]

  url "https://github.com/aiherd-dev/homebrew-aiherd/releases/download/v#{version}/aiherd-#{version}-#{arch}-apple-darwin.zip"
  name "aiherd"
  desc "Watch terminal panes and auto-detect/auto-approve prompts"
  homepage "https://aiherd-dev.github.io/"

  depends_on macos: :sonoma

  # A signed, notarized and stapled bundle. No Python: the summarizer LLM runs
  # in-process via llama.cpp, statically linked into `aih`.
  #
  # The app carries the CLI at Contents/MacOS/aih, so `binary` only has to
  # symlink it into HOMEBREW_PREFIX/bin — which brew owns. That is the whole
  # reason this cask no longer asks for a password: the .pkg it replaced had to
  # write root-owned /usr/local/bin/aih, so `installer` needed root. One file on
  # disk also means `aih` can never be a version behind the app that spawns it.
  app "AIHerd.app"
  binary "#{appdir}/AIHerd.app/Contents/MacOS/aih"

  # `app` and `binary` own their removal, including the CLI symlink in
  # HOMEBREW_PREFIX/bin. Do not add legacy /usr/local cleanup here:
  # Homebrew runs `uninstall delete:` through sudo even for missing paths,
  # and runs uninstall directives during every upgrade.
  uninstall quit: ["dev.aiherd.AIHerd"]

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
