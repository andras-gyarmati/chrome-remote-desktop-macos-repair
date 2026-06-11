# Chrome Remote Desktop macOS Repair

Repair helper for Chrome Remote Desktop Host on macOS when setup gets stuck at
`Starting...`, Chrome keeps asking to download the host again, or the local Mac
does not appear as registered even after setup.

This script was built from a real troubleshooting run on macOS 26.5.1 with
Chrome Remote Desktop Host 149.0.7827.18.

Tracked upstream:

<https://issues.chromium.org/issues/522541850>

## What It Fixes

- Missing or broken `icudtl.dat` symlinks in nested CRD helper apps.
- Broken native messaging manifests that make Chrome think the host is not installed.
- Stale half-configured host state.
- `org.chromium.chromoting` reporting `STOPPED` even though setup completed.
- The host exiting with `SUCCESS_EXIT (0)` after macOS permission prompts and not restarting.

## Usage

Install Chrome Remote Desktop Host first from:

<https://remotedesktop.google.com/access>

Then run:

```zsh
./repair-chrome-remote-desktop-macos.sh
```

For fewer prompts:

```zsh
./repair-chrome-remote-desktop-macos.sh --yes
```

The script will request administrator privileges through macOS, open the needed
Privacy panes, repair known broken files, start the host, and verify that Chrome
Remote Desktop reports:

```text
Daemon state: STARTED
```

## Required macOS Permissions

Make sure `ChromeRemoteDesktopHost.app` is enabled in:

- Accessibility
- Screen & System Audio Recording
- Remote Desktop

The script opens these panes, but macOS still requires you to approve them manually.

## Safety

The script is designed to be idempotent and safe to rerun. It backs up the
original Google LaunchAgent before installing a wrapper:

```text
/Library/LaunchAgents/org.chromium.chromoting.plist.google-original-codex
```

The wrapper runs the official Google host binary and restarts it if it exits
cleanly after permission or session changes.

Logs are written to:

```text
/tmp/org.chromium.chromoting.wrapper.log
/tmp/org.chromium.chromoting.launchd.out.log
/tmp/org.chromium.chromoting.launchd.err.log
```

## Bug Notes For Google

Chromium issue:

<https://issues.chromium.org/issues/522541850>

Observed issue:

- Host package installs and native messaging works.
- Setup creates `/Library/PrivilegedHelperTools/org.chromium.chromoting.json`.
- The host binary can connect to Google signaling and reports ready.
- The official LaunchAgent can disappear or remain stopped, so the web UI keeps
  showing setup/not registered.
- After macOS permission prompts, the host can exit with `SUCCESS_EXIT (0)` and
  launchd does not bring it back.

Observed versions:

- macOS 26.5.1
- Chrome Remote Desktop Host 149.0.7827.18

## License

MIT
