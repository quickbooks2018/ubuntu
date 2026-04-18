# Ubuntu RDP

One-script setup for xrdp on Ubuntu 22.04/24.04 with GNOME desktop.

## Quick Start

```bash
git clone <repo-url> && cd ubuntu-rdp
sudo ./ubuntu-rdp.sh
```

This installs xrdp, configures GNOME sessions, and verifies everything is working.

## What It Does

- Installs the `xrdp` package
- Adds the `xrdp` user to the `ssl-cert` group
- Configures `~/.xsessionrc` for GNOME desktop over RDP
- Creates polkit rules to suppress authentication dialogs (colord)
- Opens firewall port 3389 if ufw is active
- Enables xrdp services to start on boot

## Usage

```bash
sudo ./ubuntu-rdp.sh              # Full install + verify
sudo ./ubuntu-rdp.sh install      # Install and configure only
sudo ./ubuntu-rdp.sh verify       # Verify existing setup
./ubuntu-rdp.sh status            # Quick status check (no root needed)
sudo ./ubuntu-rdp.sh uninstall    # Remove xrdp completely
```

## Connecting

After installation, connect from any RDP client:

| Client | Command / App |
|--------|--------------|
| Windows | `mstsc` -> enter `<your-ip>:3389` |
| macOS | Microsoft Remote Desktop |
| Linux | Remmina or `xfreerdp /v:<your-ip> /u:<user>` |

Use your Ubuntu username and password to log in.

## Verify Checks

The `verify` command runs 8 checks:

1. **Package** — xrdp is installed
2. **Services** — xrdp and xrdp-sesman are running and enabled
3. **Network** — port 3389 is listening
4. **Permissions** — xrdp user in ssl-cert group
5. **Session** — `.xsessionrc` configured for GNOME
6. **Polkit** — colord rules in place
7. **Connection** — TCP handshake to localhost:3389
8. **Logs** — no recent errors in journald

## Troubleshooting

**Black screen on connect:** Log out of the local GNOME session first — GNOME doesn't handle concurrent local + remote sessions well.

**Authentication popups:** Re-run `sudo ./ubuntu-rdp.sh install` to recreate the polkit rules.

**Can't connect from remote machine:** Check that port 3389 is reachable (firewall, network). Run `./ubuntu-rdp.sh status` for a quick check.

## Requirements

- Ubuntu 22.04 or 24.04 LTS
- GNOME desktop environment
- Root/sudo access
