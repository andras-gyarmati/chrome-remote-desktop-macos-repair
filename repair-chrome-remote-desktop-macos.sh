#!/bin/zsh
set -u

# Chrome Remote Desktop macOS repair helper.
# Safe to run repeatedly. It repairs the issues seen on macOS 26.x where:
# - the CRD helper app is installed but Chrome keeps asking to download it,
# - icudtl.dat is missing from nested helper bundles,
# - the native messaging host works but the host daemon stays STOPPED,
# - the host exits cleanly after a permission prompt and launchd leaves it down.

HELPERTOOLS="/Library/PrivilegedHelperTools"
HOST_APP="$HELPERTOOLS/ChromeRemoteDesktopHost.app"
HOST_BUNDLE_LINK="$HELPERTOOLS/ChromeRemoteDesktopHost.bundle"
HOST_SERVICE="$HOST_APP/Contents/MacOS/remoting_me2me_host_service"
NATIVE_HOST="$HOST_APP/Contents/MacOS/NativeMessagingHost.app/Contents/MacOS/native_messaging_host"
MAIN_ICU="$HOST_APP/Contents/Resources/icudtl.dat"
NATIVE_ICU="$HOST_APP/Contents/MacOS/NativeMessagingHost.app/Contents/Resources/icudtl.dat"
ASSIST_ICU="$HOST_APP/Contents/MacOS/RemoteAssistanceHost.app/Contents/Resources/icudtl.dat"
LAUNCH_AGENT="/Library/LaunchAgents/org.chromium.chromoting.plist"
BROKER_DAEMON="/Library/LaunchDaemons/org.chromium.chromoting.broker.plist"
WRAPPER="$HELPERTOOLS/org.chromium.chromoting.launch-wrapper.sh"
ORIGINAL_PLIST_BACKUP="$LAUNCH_AGENT.google-original-codex"
CONFIG_JSON="$HELPERTOOLS/org.chromium.chromoting.json"
ENABLED_FILE="$HELPERTOOLS/org.chromium.chromoting.me2me_enabled"
CHROME_MANIFEST_DIR="/Library/Google/Chrome/NativeMessagingHosts"
CRD_MANIFEST="$CHROME_MANIFEST_DIR/com.google.chrome.remote_desktop.json"
REMOTE_ASSIST_MANIFEST="$CHROME_MANIFEST_DIR/com.google.chrome.remote_assistance.json"
WEBAUTHN_MANIFEST="$CHROME_MANIFEST_DIR/com.google.chrome.remote_webauthn.json"
LOG="/tmp/org.chromium.chromoting.wrapper.log"

YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./repair-chrome-remote-desktop-macos.sh [--yes]

Repairs a Chrome Remote Desktop host install on macOS and guides you through
required Privacy permissions. Run without --yes for prompts.
EOF
      exit 0
      ;;
  esac
done

info() { print -r -- "==> $*"; }
warn() { print -r -- "WARN: $*" >&2; }
fail() { print -r -- "ERROR: $*" >&2; exit 1; }

ask() {
  local prompt="$1"
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  print -n -- "$prompt [y/N] "
  local reply
  read reply
  [[ "$reply" == [Yy]* ]]
}

run_root_script() {
  local tmp
  tmp="$(mktemp /tmp/crd-repair-root.XXXXXX)" || exit 1
  cat > "$tmp"
  chmod 700 "$tmp"
  osascript -e 'on run argv' \
    -e 'do shell script "/bin/sh " & quoted form of item 1 of argv with administrator privileges' \
    -e 'end run' "$tmp"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

run_installer_pkg() {
  local pkg="$1"
  osascript -e 'on run argv' \
    -e 'do shell script "installer -pkg " & quoted form of item 1 of argv & " -target /" with administrator privileges' \
    -e 'end run' "$pkg"
}

repair_from_google_installer() {
  local pkg="/Volumes/Chrome Remote Desktop Host 149.0.7827.18/Chrome Remote Desktop Host.pkg"
  if [[ ! -f "$pkg" && -f "$HOME/Downloads/chromeremotedesktop.dmg" ]]; then
    info "Mounting downloaded Chrome Remote Desktop DMG"
    hdiutil attach -nobrowse -readonly "$HOME/Downloads/chromeremotedesktop.dmg" >/dev/null || true
  fi
  pkg="/Volumes/Chrome Remote Desktop Host 149.0.7827.18/Chrome Remote Desktop Host.pkg"
  if [[ -f "$pkg" ]]; then
    info "Running signed Google installer to restore helper bundle layout"
    run_installer_pkg "$pkg"
    return $?
  fi
  return 1
}

native_roundtrip() {
  /usr/bin/perl -MJSON::PP -e '
    use strict; use warnings;
    use IPC::Open3;
    use Symbol "gensym";
    my $bin = shift;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, $bin, "chrome-extension://inomeogfingihgjfjlpeplalcfajhgai/");
    binmode($in); binmode($out);
    my $json = encode_json({ id => 1, type => "hello" });
    print $in pack("V", length($json)) . $json;
    close($in);
    read($out, my $lenbuf, 4) == 4 or die "no response";
    my $len = unpack("V", $lenbuf);
    read($out, my $body, $len) == $len or die "short response";
    print $body, "\n";
    waitpid($pid, 0);
  ' "$NATIVE_HOST" 2>/tmp/crd-native-hello.err
}

daemon_state() {
  /usr/bin/perl -MJSON::PP -e '
    use strict; use warnings;
    use IPC::Open3;
    use Symbol "gensym";
    my $bin = shift;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, $bin, "chrome-extension://inomeogfingihgjfjlpeplalcfajhgai/");
    binmode($in); binmode($out);
    my $json = encode_json({ id => 1, type => "getDaemonState" });
    print $in pack("V", length($json)) . $json;
    close($in);
    read($out, my $lenbuf, 4) == 4 or die "no response";
    my $len = unpack("V", $lenbuf);
    read($out, my $body, $len) == $len or die "short response";
    my $obj = decode_json($body);
    print(($obj->{state} // "UNKNOWN"), "\n");
    waitpid($pid, 0);
  ' "$NATIVE_HOST" 2>/tmp/crd-daemon-state.err
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This script is for macOS only."

info "Checking Chrome Remote Desktop host install"
if [[ ! -d "$HOST_APP" || ! -x "$HOST_SERVICE" || ! -x "$NATIVE_HOST" ]]; then
  warn "Chrome Remote Desktop Host is not installed or is incomplete."
  warn "Install it from https://remotedesktop.google.com/access first, then rerun this script."
  if [[ -f "$HOME/Downloads/chromeremotedesktop.dmg" ]]; then
    warn "Found $HOME/Downloads/chromeremotedesktop.dmg. Open it and run the pkg if needed."
  fi
  exit 2
fi

info "Repairing helper symlinks and native messaging manifests"
run_root_script <<ROOT
set -eu
mkdir -p "$CHROME_MANIFEST_DIR"
rm -f "$HOST_BUNDLE_LINK"
ln -s "$HOST_APP" "$HOST_BUNDLE_LINK"

repair_icu_link() {
  target="\$1"
  current="\$(readlink "\$target" 2>/dev/null || true)"
  if [ "\$current" != "$MAIN_ICU" ]; then
    rm -f "\$target" 2>/dev/null || true
    ln -s "$MAIN_ICU" "\$target" 2>/dev/null || true
  fi
}

if [ -f "$MAIN_ICU" ]; then
  repair_icu_link "$NATIVE_ICU"
  repair_icu_link "$ASSIST_ICU"
fi

cat > "$CRD_MANIFEST" <<'JSON'
{
  "allowed_origins": [
    "chrome-extension://inomeogfingihgjfjlpeplalcfajhgai/"
  ],
  "description": "Chrome Remote Desktop Host",
  "name": "com.google.chrome.remote_desktop",
  "path": "/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/Contents/MacOS/NativeMessagingHost.app/Contents/MacOS/native_messaging_host",
  "type": "stdio"
}
JSON

cat > "$REMOTE_ASSIST_MANIFEST" <<'JSON'
{
  "allowed_origins": [
    "chrome-extension://inomeogfingihgjfjlpeplalcfajhgai/"
  ],
  "description": "Remote Assistance Host for Chrome Remote Desktop",
  "name": "com.google.chrome.remote_assistance",
  "path": "/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/Contents/MacOS/RemoteAssistanceHost.app/Contents/MacOS/remote_assistance_host",
  "type": "stdio"
}
JSON

cat > "$WEBAUTHN_MANIFEST" <<'JSON'
{
  "allowed_origins": [
    "chrome-extension://inomeogfingihgjfjlpeplalcfajhgai/",
    "chrome-extension://djjmngfglakhkhmgcfdmjalogilepkhd/"
  ],
  "description": "Remote Web Authentication Process for Chrome Remote Desktop",
  "name": "com.google.chrome.remote_webauthn",
  "path": "/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/Contents/MacOS/remote_webauthn",
  "type": "stdio"
}
JSON

chown root:wheel "$CRD_MANIFEST" "$REMOTE_ASSIST_MANIFEST" "$WEBAUTHN_MANIFEST"
chmod 644 "$CRD_MANIFEST" "$REMOTE_ASSIST_MANIFEST" "$WEBAUTHN_MANIFEST"
ROOT

info "Testing native messaging helper"
hello="$(native_roundtrip || true)"
if [[ "$hello" != *'"helloResponse"'* ]]; then
  warn "Native messaging did not return helloResponse; trying Google installer fallback."
  sed -n '1,80p' /tmp/crd-native-hello.err >&2
  if repair_from_google_installer; then
    hello="$(native_roundtrip || true)"
  fi
  if [[ "$hello" != *'"helloResponse"'* ]]; then
    warn "Native messaging still did not return helloResponse."
    warn "stderr:"
    sed -n '1,80p' /tmp/crd-native-hello.err >&2
    fail "Chrome will not detect the host until native messaging works."
  fi
fi
print -r -- "$hello"

info "Opening required macOS Privacy panes"
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' >/dev/null 2>&1 || true
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' >/dev/null 2>&1 || true
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_RemoteDesktop' >/dev/null 2>&1 || true
warn "Make sure ChromeRemoteDesktopHost.app is enabled in Accessibility, Screen & System Audio Recording, and Remote Desktop."
if ! ask "Continue after confirming those permissions are enabled?"; then
  warn "Stopped before launchd repair. Rerun after enabling permissions."
  exit 0
fi

info "Installing persistent launchd wrapper"
run_root_script <<ROOT
set -eu
if [ -f "$LAUNCH_AGENT" ] && [ ! -f "$ORIGINAL_PLIST_BACKUP" ]; then
  cp "$LAUNCH_AGENT" "$ORIGINAL_PLIST_BACKUP"
fi

cat > "$WRAPPER" <<'EOF'
#!/bin/sh
LOG=/tmp/org.chromium.chromoting.wrapper.log
while true; do
  /Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/Contents/MacOS/remoting_me2me_host_service --run-from-launchd >> "\$LOG" 2>&1
  code=\$?
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] remoting_me2me_host_service exited with code \$code; restarting in 3s" >> "\$LOG"
  sleep 3
done
EOF
chown root:wheel "$WRAPPER"
chmod 755 "$WRAPPER"

cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Disabled</key>
  <false/>
  <key>Label</key>
  <string>org.chromium.chromoting</string>
  <key>LimitLoadToSessionType</key>
  <array>
    <string>Aqua</string>
    <string>LoginWindow</string>
  </array>
  <key>ProgramArguments</key>
  <array>
    <string>$WRAPPER</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/org.chromium.chromoting.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/org.chromium.chromoting.launchd.err.log</string>
</dict>
</plist>
EOF
chown root:wheel "$LAUNCH_AGENT"
chmod 644 "$LAUNCH_AGENT"
ROOT

info "Starting broker and host launch agents"
run_root_script <<ROOT
set -eu
rm -f /tmp/org.chromium.chromoting.wrapper.log \
      /tmp/org.chromium.chromoting.launchd.out.log \
      /tmp/org.chromium.chromoting.launchd.err.log
touch /tmp/org.chromium.chromoting.wrapper.log \
      /tmp/org.chromium.chromoting.launchd.out.log \
      /tmp/org.chromium.chromoting.launchd.err.log
chown "$(id -un)":"$(id -gn)" /tmp/org.chromium.chromoting.wrapper.log \
      /tmp/org.chromium.chromoting.launchd.out.log \
      /tmp/org.chromium.chromoting.launchd.err.log
chmod 666 /tmp/org.chromium.chromoting.wrapper.log \
      /tmp/org.chromium.chromoting.launchd.out.log \
      /tmp/org.chromium.chromoting.launchd.err.log
ROOT

launchctl enable system/org.chromium.chromoting.broker >/dev/null 2>&1 || true
launchctl bootstrap system "$BROKER_DAEMON" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
launchctl kickstart -kp "gui/$(id -u)/org.chromium.chromoting" >/dev/null 2>&1 || true

info "Waiting for host to start"
sleep 8
state="$(daemon_state || true)"
print -r -- "Daemon state: ${state:-UNKNOWN}"
tail -40 "$LOG" 2>/dev/null || true

if [[ "$state" == "STARTED" ]]; then
  info "Chrome Remote Desktop host is STARTED. Refresh https://remotedesktop.google.com/access."
  exit 0
fi

warn "Host is not STARTED yet."
warn "If this is a fresh install, finish the Turn on/PIN setup in Chrome, then rerun this script."
warn "If it is already configured, inspect $LOG and rerun."
exit 3
