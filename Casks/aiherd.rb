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

  version "6.0.6"
  shas = {
    arm:   "1776827ac23dd0100dafe53d8677c841598497e7d775ae32f5595dd6c4ce8011",
    intel: "0c8de9aa2c3da656ca3781b7a6973beec57e3f637a63c0461819521e5bd3eba0",
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

  # The herd is a login service (dev.aiherd.herd), started here so a brew
  # install needs no app launch. Not `uninstall launchctl:`: it probes through
  # sudo and gives the herd one second, and the herd needs to park its ssh
  # sessions first. Brew runs this on every upgrade too; the owned terminals
  # stay with the keeper and the new herd adopts them in postflight.
  uninstall_preflight do
    system_command "#{appdir}/AIHerd.app/Contents/MacOS/aih",
                   args: ["uninstall-launchd"], must_succeed: false
  end

  # Fails without a GUI login session (brew over ssh); the app, or
  # `aih install-launchd` at the Mac, does it then.
  postflight do
    system_command "#{appdir}/AIHerd.app/Contents/MacOS/aih",
                   args: ["install-launchd"], must_succeed: false
  end

  # The text index, settings and downloaded model weights the CLI builds at
  # runtime; `brew uninstall --zap` removes them, plain uninstall leaves them.
  zap trash: [
    "~/Library/Application Support/aiherd",
    "~/Library/Logs/aiherd-serve.log",
  ]

  caveats <<~EOS
    The herd (`aih serve`) now runs as a login service, dev.aiherd.herd,
    over a Unix socket; AIHerd.app is its window. Upgrades restart it and
    keep its terminals and ssh sessions. To stop it for good:
      aih uninstall-launchd

    The stable-terminal summarizer needs Apple Silicon with 16 GB or more. On
    first use it downloads the model (~2.5 GB) into
    ~/Library/Application Support/aiherd/models; the dashboard shows the
    download progress on the pane that triggered it.
  EOS
end
