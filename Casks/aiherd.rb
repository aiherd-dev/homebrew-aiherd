cask "aiherd" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.3.0"
  sha256 arm:   "f26ac49604c063e51b1576cee1eef9d8babf886a8e5f1c92964200faa6ac6e1b",
         intel: "a5affaeb85648cc25b233e040a0de57d7f4e46b788f49fb03845aae487bd54db"

  url "https://github.com/aiherd-dev/homebrew-aiherd/releases/download/v#{version}/aiherd-#{version}-#{arch}-apple-darwin.tar.gz"
  name "aiherd"
  desc "Watch terminal panes and auto-detect/auto-approve prompts"
  homepage "https://github.com/aiherd-dev/aiherd"

  depends_on :macos

  # Native SwiftUI dashboard (a client of the local `aih serve` API).
  app "Aiherd.app"
  # Self-contained CLI: the SetFit question-detection model is embedded, so there
  # is no Python/uv/venv dependency.
  binary "aih"

  # Both artifacts are Developer ID signed with a hardened runtime and notarized.
  # Aiherd.app has its notarization ticket stapled, so it validates offline and
  # needs no help here. A bare Mach-O cannot be stapled, so quarantined `aih`
  # would force an online Gatekeeper lookup on first run (and fail offline) —
  # strip the flag for the CLI only.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{staged_path}/aih"]
  end

  caveats <<~EOS
    Just open Aiherd.app — it starts `aih serve` itself
    (over a Unix socket; no TCP port is taken). To also reach the dashboard
    from a phone/browser, run `aih serve -p 8080` yourself.
  EOS
end
