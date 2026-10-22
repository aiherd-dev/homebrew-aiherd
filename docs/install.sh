#!/usr/bin/env bash
# Canonical source for https://aiherd.dev/install.sh.
# Installs the headless herd as the current user's systemd service.
set -euo pipefail

fail() { printf 'AIHerd: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Install $1, then run this installer again."; }

[ "$(uname -s)" = Linux ] || fail 'This installer is for Linux. On macOS use: brew install --cask aiherd-dev/aiherd/aiherd'
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) fail 'Linux releases support x86_64 and aarch64 (ARM64).' ;;
esac
for tool in curl tar sha256sum awk grep install mktemp systemctl loginctl seq id; do need "$tool"; done

repo=https://github.com/aiherd-dev/homebrew-aiherd
version=${AIHERD_VERSION:-}
if [ -z "$version" ]; then
  release=$(curl --fail --silent --show-error --location --head --output /dev/null --write-out '%{url_effective}' "$repo/releases/latest")
  version=${release##*/}
fi
version=${version#v}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail 'Could not resolve a stable AIHerd release.'
base="$repo/releases/download/v$version"
libc=${AIHERD_LINUX_LIBC:-auto}
if [ "$libc" = auto ]; then
  status=$(curl --silent --show-error --location --head --output /dev/null --write-out '%{http_code}' "$base/aiherd-${version}-${arch}-linux-musl-terminal.tar.gz") || fail 'Could not check the static Linux release.'
  case "$status" in
    200) libc=musl ;;
    404) libc=gnu ;;
    *) fail "Static release lookup returned HTTP $status. Try again later." ;;
  esac
fi
case "$libc" in
  musl) ;;
  gnu)
    need getconf
    need ldd
    detected_libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || fail 'This older release requires glibc. Select a release with a static musl package.'
    if ! printf '%s\n' "$detected_libc" | awk '$1 == "glibc" { split($2, v, "."); if (v[1] > 2 || (v[1] == 2 && v[2] >= 39)) ok=1 } END { exit !ok }'; then
      fail "This GNU package needs glibc 2.39 or newer; found $detected_libc. Select a release with a static musl package."
    fi
    ;;
  *) fail 'AIHERD_LINUX_LIBC must be auto, musl or gnu.' ;;
esac
archive="aiherd-${version}-${arch}-linux-${libc}-terminal.tar.gz"
work=$(mktemp -d "${TMPDIR:-/tmp}/aih-install.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
umask 077

printf 'Downloading AIHerd %s for headless Linux (%s, %s)…\n' "$version" "$arch" "$libc"
curl --fail --show-error --location --retry 3 --output "$work/$archive" "$base/$archive" || fail "No $arch Linux $libc package is available for v$version. Check $repo/releases."
curl --fail --silent --show-error --location --retry 3 --output "$work/checksum" "$base/$archive.sha256"
expected=$(awk 'NR == 1 { print $1 }' "$work/checksum")
printf '%s\n' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$' || fail 'Invalid release checksum.'
actual=$(sha256sum "$work/$archive" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail 'Release checksum mismatch. Nothing was installed.'

mkdir "$work/package"
tar -xzf "$work/$archive" --strip-components=1 -C "$work/package"
for binary in aih aih-fdkeeper aih-rdpauth; do
  [ -f "$work/package/bin/$binary" ] && [ ! -L "$work/package/bin/$binary" ] || fail "Release is missing bin/$binary."
  if [ "$libc" = gnu ]; then
    if ! libraries=$(ldd "$work/package/bin/$binary" 2>&1) || printf '%s\n' "$libraries" | grep -q 'not found'; then
      printf '%s\n' "$libraries" >&2
      fail 'Missing runtime libraries. On Ubuntu/Debian run: sudo apt-get install libsqlite3-0 libgomp1 libstdc++6 libgcc-s1'
    fi
  fi
done
"$work/package/bin/aih" --version

# Linger starts the user manager on boot and keeps it after the SSH session ends.
username=$(id -un)
linger=$(loginctl show-user "$username" --property=Linger --value 2>/dev/null || true)
if [ "$linger" != yes ]; then
  printf 'Enabling service startup at boot and after SSH logout…\n'
  if ! loginctl enable-linger --no-ask-password "$username"; then
    need sudo
    sudo loginctl enable-linger "$username" || fail "Enable lingering with: sudo loginctl enable-linger $username"
  fi
fi
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
for attempt in $(seq 1 30); do
  if systemctl --user show-environment >/dev/null 2>&1; then break; fi
  sleep 1
done
systemctl --user show-environment >/dev/null 2>&1 || fail 'No systemd user manager is available. Reconnect with SSH after enabling lingering, then rerun the installer.'

bindir=${AIHERD_BIN_DIR:-$HOME/.local/bin}
case "$bindir" in /*) ;; *) fail 'AIHERD_BIN_DIR must be an absolute path.' ;; esac
mkdir -p "$bindir"
for binary in aih aih-fdkeeper aih-rdpauth; do
  install -m 755 "$work/package/bin/$binary" "$bindir/.$binary-install-$$"
  mv -f "$bindir/.$binary-install-$$" "$bindir/$binary"
done
"$bindir/aih" install-systemd
config=${XDG_CONFIG_HOME:-$HOME/.config}
case "$config" in /*) ;; *) config=$HOME/.config ;; esac
dropin="$config/systemd/user/aih.service.d/aih-installer.conf"
[ ! -L "$dropin" ] || fail "Refusing to replace the symlink at $dropin."
if [ -e "$dropin" ] && ! grep -q '^# Installed by AIHerd Linux installer$' "$dropin"; then
  fail "A custom installer override exists at $dropin. Keep or remove it before reinstalling."
fi
mkdir -p "${dropin%/*}"
# Keep this override identical to packaging/linux/headless.conf in the repo.
cat >"$dropin" <<'HEADLESS'
# Installed by AIHerd Linux installer
[Service]
Environment="PATH=%h/.local/bin:%h/.cargo/bin:%h/.bun/bin:/usr/local/bin:/usr/bin:/bin"
UnsetEnvironment=DISPLAY WAYLAND_DISPLAY
HEADLESS
systemctl --user daemon-reload
systemctl --user restart aih.service

# Prepare relay discovery now; authentication gates actual remote access.
# The server remembers this choice and restores it after service restarts.
socket="$XDG_RUNTIME_DIR/aiherd.sock"
for attempt in $(seq 1 60); do
  if curl --fail --silent --show-error --max-time 2 --unix-socket "$socket" http://localhost/api/herd >"$work/herd.json" 2>/dev/null; then break; fi
  sleep 1
done
curl --fail --silent --show-error --max-time 60 --unix-socket "$socket" \
  -X POST http://localhost/api/relay >"$work/relay.json" || fail 'The service did not prepare relay access. Check: journalctl --user -u aih.service'
if ! grep -Eq '"phase"[[:space:]]*:[[:space:]]*"serving"' "$work/relay.json"; then
  cat "$work/relay.json" >&2
  fail 'Relay discovery failed. Check: journalctl --user -u aih.service, then rerun the installer when connected.'
fi
systemctl --user is-active --quiet aih.service || fail 'The service stopped. Check: journalctl --user -u aih.service'

printf '\nAIHerd is installed and running as your user. Models download on first run.\n'
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) printf '\nAdd the installed commands to this shell:\n  export PATH=%q:"$PATH"\n' "$bindir" ;;
esac
printf '\n1. Sign in to expose the herd:\n  aih login\n\nOpen the printed sign-in URL on your phone or another computer.\n\n2. Add your mobile device:\n  aih join\n\nScan the QR code or open the link, then approve pairing in this terminal.\n\nService status: systemctl --user status aih.service\nLogs: journalctl --user -u aih.service -f\n'
