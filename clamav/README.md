# ClamAV For Ubuntu

This guide is written so an Ubuntu user can publish it directly and use it on another machine without machine-specific edits.

It installs and configures:

- `clamav`
- `clamav-daemon`
- `clamdscan`
- `clamav-freshclam`
- `clamonacc`
- a daily scheduled scan with `systemd`
- on-access monitoring for common user folders
- quarantine on detection
- separate logs for daemon, updater, on-access, and scheduled scans

Tested design target:

- Ubuntu 24.04 and similar Debian-based Ubuntu releases using `apt` and `systemd`

## What This Setup Does

After installation:

- signatures are updated automatically by `freshclam`
- `clamd` stays running in memory for faster scans
- a daily scan runs automatically through `systemd`
- on-access scanning monitors:
  - `~/Downloads`
  - `~/Desktop`
  - `~/Documents`
  - `~/Public`
- detected files from on-access scanning are moved to quarantine
- the daily scan walks readable files under the watched user folders

This is not meant to behave exactly like Microsoft Defender or Bitdefender. It is a practical Ubuntu-native ClamAV setup focused on:

- automated updates
- fast daemon-backed scans
- on-access protection for high-risk folders
- predictable logging
- low enough overhead for daily use

## Installed Components

Packages installed:

- `clamav`
- `clamav-base`
- `clamav-daemon`
- `clamav-freshclam`
- `clamdscan`

Main tools:

- `clamscan`: standalone scanner
- `clamd`: resident daemon
- `clamdscan`: client for daemon-backed scans
- `freshclam`: signature updater
- `clamonacc`: on-access scanner

## Paths Created By This Setup

Config files:

- `/etc/clamav/clamd.conf`
- `/etc/clamav/freshclam.conf`
- `/etc/clamav/onaccess.watch`
- `/etc/clamav/onaccess.exclude`
- `/etc/systemd/system/clamav-daily-scan.service`
- `/etc/systemd/system/clamav-daily-scan.timer`
- `/etc/systemd/system/clamav-clamonacc.service.d/override.conf`
- `/usr/local/bin/clamav-daily-scan`

Runtime and data paths:

- signature database: `/var/lib/clamav`
- quarantine: `/var/lib/clamav/quarantine`
- daemon socket: `/var/run/clamav/clamd.ctl`
- log directory: `/var/log/clamav`

## Logs

Logs used by this setup:

- daemon log: `/var/log/clamav/clamav.log`
- on-access log: `/var/log/clamav/clamonacc.log`
- scheduled scan log: `/var/log/clamav/daily-scan.log`
- updater log: `/var/log/clamav/freshclam.log`

Useful commands:

```bash
ls -l /var/log/clamav
tail -n 80 /var/log/clamav/daily-scan.log
tail -n 80 /var/log/clamav/freshclam.log
sudo tail -n 80 /var/log/clamav/clamav.log
sudo tail -n 80 /var/log/clamav/clamonacc.log
```

## Schedule

The installed daily timer runs:

- every day at `02:00`
- with up to `15 minutes` randomized delay
- with `Persistent=true`, so missed runs can be triggered after boot

Useful commands:

```bash
systemctl cat clamav-daily-scan.timer
systemctl list-timers --all | grep clamav-daily-scan
```

## Daily Scan Behavior

The daily scan script:

- scans `~/Downloads`, `~/Desktop`, `~/Documents`, and `~/Public`
- uses `find` to collect readable regular files
- batches files into groups and submits them to `clamdscan`
- avoids handing recursive directories directly to `clamdscan`
- recursively includes user-created folders under those paths, including any folder created under `~/Desktop`

Why:

- recursive directory scans with `clamdscan` can be noisy or inefficient on large dev trees
- batching regular files is more stable
- using `find` over the full directory tree ensures newly added user folders are included in the scheduled scan

## On-Access Behavior

On-access scanning uses `clamonacc`.

Watched folders:

- `~/Downloads`
- `~/Desktop`
- `~/Documents`
- `~/Public`

Excluded folders:

- none by default

Detected files are moved to:

- `/var/lib/clamav/quarantine`

## One-Command Installer

The block below is designed so a user can copy, paste, and run it in one shot on Ubuntu.

What it does:

- installs required packages
- creates the ClamAV config files
- creates the daily scan script
- creates the daily scan service and timer
- enables and starts `clamd`
- enables and starts `clamonacc`
- enables the daily timer
- prints final status commands

Copy and run:

```bash
cat <<'EOF' >/tmp/setup-clamav-ubuntu.sh
#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer with sudo:"
  echo "sudo bash /tmp/setup-clamav-ubuntu.sh"
  exit 1
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  echo "Unable to determine the target desktop user."
  echo "Run as: sudo bash /tmp/setup-clamav-ubuntu.sh from the user session you want to protect."
  exit 1
fi

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
if [[ -z "${TARGET_HOME}" || ! -d "${TARGET_HOME}" ]]; then
  echo "Unable to determine home directory for ${TARGET_USER}."
  exit 1
fi

SCAN_PATHS=(
  "${TARGET_HOME}/Downloads"
  "${TARGET_HOME}/Desktop"
  "${TARGET_HOME}/Documents"
  "${TARGET_HOME}/Public"
)

mkdir -p /etc/clamav
mkdir -p /etc/systemd/system/clamav-clamonacc.service.d
mkdir -p /var/lib/clamav/quarantine
mkdir -p /var/log/clamav

apt-get update
apt-get install -y clamav clamav-daemon clamdscan clamav-freshclam

cat >/etc/clamav/clamd.conf <<'CLAMD'
# Managed by setup-clamav-ubuntu.sh
LocalSocket /var/run/clamav/clamd.ctl
FixStaleSocket true
LocalSocketGroup clamav
LocalSocketMode 666
User clamav
ScanMail true
ScanArchive true
ArchiveBlockEncrypted false
MaxDirectoryRecursion 15
FollowDirectorySymlinks false
FollowFileSymlinks false
ReadTimeout 180
MaxThreads 12
MaxConnectionQueueLength 15
LogSyslog false
LogRotate true
LogFacility LOG_LOCAL6
LogClean false
LogVerbose false
DatabaseDirectory /var/lib/clamav
OfficialDatabaseOnly false
SelfCheck 3600
Foreground false
Debug false
ScanPE true
MaxEmbeddedPE 10M
ScanOLE2 true
ScanPDF true
ScanHTML true
MaxHTMLNormalize 10M
MaxHTMLNoTags 2M
MaxScriptNormalize 5M
MaxZipTypeRcg 1M
ScanSWF true
ExitOnOOM false
LeaveTemporaryFiles false
AlgorithmicDetection true
ScanELF true
IdleTimeout 30
CrossFilesystems true
PhishingSignatures true
PhishingScanURLs true
PhishingAlwaysBlockSSLMismatch false
PhishingAlwaysBlockCloak false
PartitionIntersection false
DetectPUA false
ScanPartialMessages false
HeuristicScanPrecedence false
StructuredDataDetection false
CommandReadTimeout 30
SendBufTimeout 200
MaxQueue 100
ExtendedDetectionInfo true
OLE2BlockMacros false
AllowAllMatchScan true
ForceToDisk false
DisableCertCheck false
DisableCache false
MaxScanTime 120000
MaxScanSize 100M
MaxFileSize 25M
MaxRecursion 16
MaxFiles 10000
MaxPartitions 50
MaxIconsPE 100
PCREMatchLimit 10000
PCRERecMatchLimit 5000
PCREMaxFileSize 25M
ScanXMLDOCS true
ScanHWP3 true
MaxRecHWP3 16
StreamMaxLength 25M
LogFile /var/log/clamav/clamav.log
LogTime true
LogFileUnlock false
LogFileMaxSize 0
Bytecode true
BytecodeSecurity TrustSigned
BytecodeTimeout 60000
OnAccessMaxFileSize 25M
OnAccessExcludeUname clamav
CLAMD

{
  for path in "${SCAN_PATHS[@]}"; do
    [[ -d "${path}" ]] && echo "${path}"
  done
} >/etc/clamav/onaccess.watch

: >/etc/clamav/onaccess.exclude

cat >/etc/systemd/system/clamav-clamonacc.service.d/override.conf <<'OVERRIDE'
[Service]
ExecStart=
ExecStart=/usr/sbin/clamonacc -F --fdpass --log=/var/log/clamav/clamonacc.log --move=/var/lib/clamav/quarantine --watch-list=/etc/clamav/onaccess.watch --exclude-list=/etc/clamav/onaccess.exclude
ExecStop=
ExecStop=/bin/kill -SIGTERM $MAINPID
OVERRIDE

printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' '' "TARGET_HOME=$(printf '%q' "${TARGET_HOME}")" '' >/usr/local/bin/clamav-daily-scan

cat >>/usr/local/bin/clamav-daily-scan <<'SCAN'
SCAN_PATHS=(
  "${TARGET_HOME}/Downloads"
  "${TARGET_HOME}/Desktop"
  "${TARGET_HOME}/Documents"
  "${TARGET_HOME}/Public"
)

BATCH_SIZE=200
LOG_FILE="/var/log/clamav/daily-scan.log"
START_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
ACTIVE_SCAN_PATHS=()

mkdir -p "$(dirname "${LOG_FILE}")"

for path in "${SCAN_PATHS[@]}"; do
  [[ -d "${path}" ]] && ACTIVE_SCAN_PATHS+=("${path}")
done

if [[ "${#ACTIVE_SCAN_PATHS[@]}" -eq 0 ]]; then
  END_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${END_STAMP}] Scan aborted: no valid scan paths were found" >> "${LOG_FILE}"
  exit 2
fi

echo "[${START_STAMP}] Starting ClamAV daily scan for: ${ACTIVE_SCAN_PATHS[*]}" >> "${LOG_FILE}"

if ! systemctl is-active --quiet clamav-daemon.service; then
  END_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${END_STAMP}] Scan aborted: clamav-daemon.service is not running" >> "${LOG_FILE}"
  exit 2
fi

STATUS=0
FILES_SCANNED=0
declare -a BATCH=()

scan_batch() {
  local batch_status=0

  if [[ "${#BATCH[@]}" -eq 0 ]]; then
    return 0
  fi

  FILES_SCANNED=$((FILES_SCANNED + ${#BATCH[@]}))

  if /usr/bin/clamdscan --fdpass --infected --log="${LOG_FILE}" "${BATCH[@]}"; then
    batch_status=0
  else
    batch_status=$?
  fi

  BATCH=()
  return "${batch_status}"
}

while IFS= read -r -d '' FILE_PATH; do
  BATCH+=("${FILE_PATH}")

  if [[ "${#BATCH[@]}" -ge "${BATCH_SIZE}" ]]; then
    if scan_batch; then
      :
    else
      BATCH_STATUS=$?
      if [[ "${BATCH_STATUS}" -eq 1 ]]; then
        STATUS=1
      else
        STATUS="${BATCH_STATUS}"
        break
      fi
    fi
  fi
done < <(
  find "${ACTIVE_SCAN_PATHS[@]}" -type f -readable -print0
)

if [[ "${STATUS}" -eq 0 || "${STATUS}" -eq 1 ]]; then
  if scan_batch; then
    :
  else
    BATCH_STATUS=$?
    if [[ "${BATCH_STATUS}" -eq 1 ]]; then
      STATUS=1
    else
      STATUS="${BATCH_STATUS}"
    fi
  fi
fi

END_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
echo "[${END_STAMP}] Files submitted to clamdscan: ${FILES_SCANNED}" >> "${LOG_FILE}"

if [[ "${STATUS}" -eq 0 ]]; then
  echo "[${END_STAMP}] Scan completed: no threats found" >> "${LOG_FILE}"
elif [[ "${STATUS}" -eq 1 ]]; then
  echo "[${END_STAMP}] Scan completed: threats found" >> "${LOG_FILE}"
else
  echo "[${END_STAMP}] Scan completed with error code ${STATUS}" >> "${LOG_FILE}"
fi

exit "${STATUS}"
SCAN

chmod 0755 /usr/local/bin/clamav-daily-scan

cat >/etc/systemd/system/clamav-daily-scan.service <<'SERVICE'
[Unit]
Description=Daily ClamAV scan
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/clamav-daily-scan
SuccessExitStatus=1
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SERVICE

cat >/etc/systemd/system/clamav-daily-scan.timer <<'TIMER'
[Unit]
Description=Run ClamAV daily scan once per day

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=15m
Unit=clamav-daily-scan.service

[Install]
WantedBy=timers.target
TIMER

chown root:clamav /var/lib/clamav/quarantine
chmod 0750 /var/lib/clamav/quarantine

systemctl daemon-reload
systemctl enable --now clamav-daemon.service
systemctl enable --now clamav-freshclam.service
systemctl enable --now clamav-clamonacc.service
systemctl enable --now clamav-daily-scan.timer

echo
echo "ClamAV setup complete for user: ${TARGET_USER}"
echo
echo "Check status:"
echo "  systemctl status clamav-daemon clamav-freshclam clamav-clamonacc clamav-daily-scan.timer --no-pager"
echo
echo "Check next run:"
echo "  systemctl list-timers --all | grep clamav-daily-scan"
echo
echo "Run daily scan now:"
echo "  sudo systemctl start clamav-daily-scan.service"
echo
echo "Check logs:"
echo "  tail -n 80 /var/log/clamav/daily-scan.log"
echo "  tail -n 80 /var/log/clamav/freshclam.log"
echo "  sudo tail -n 80 /var/log/clamav/clamav.log"
echo "  sudo tail -n 80 /var/log/clamav/clamonacc.log"
EOF
chmod +x /tmp/setup-clamav-ubuntu.sh
sudo bash /tmp/setup-clamav-ubuntu.sh
```

## Post-Install Verification

Check services:

```bash
systemctl status clamav-daemon clamav-freshclam clamav-clamonacc clamav-daily-scan.timer --no-pager
```

Check the next scheduled run:

```bash
systemctl list-timers --all | grep clamav-daily-scan
```

Run the daily scan manually:

```bash
sudo systemctl start clamav-daily-scan.service
systemctl status clamav-daily-scan.service --no-pager
tail -n 80 /var/log/clamav/daily-scan.log
```

Run a direct manual file scan:

```bash
clamscan /path/to/file
clamdscan --fdpass /path/to/file
```

## EICAR Test

For a safe functional malware-detection test, use the EICAR test string.

Create the file:

```bash
cat > ~/eicar.com.txt <<'EOF'
X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*
EOF
```

Manual scan test:

```bash
clamscan ~/eicar.com.txt
clamdscan --fdpass ~/eicar.com.txt
```

On-access test:

```bash
cp ~/eicar.com.txt ~/Downloads/eicar.com.txt
sudo tail -n 40 /var/log/clamav/clamonacc.log
```

Expected result:

- manual scans should report `Eicar-Signature FOUND`
- if copied into a watched folder, `clamonacc` should move it to `/var/lib/clamav/quarantine`

Clean up:

```bash
rm -f ~/eicar.com.txt ~/Downloads/eicar.com.txt
sudo rm -f /var/lib/clamav/quarantine/eicar.com.txt
```

## Notes

- `clamav.log` and `clamonacc.log` usually require `sudo`
- `freshclam` can log an older `NotifyClamd` error if it ran before `clamd.conf` existed during initial setup
- if a user keeps huge development trees on the desktop, reduce the watched paths or add custom `find` pruning in `/usr/local/bin/clamav-daily-scan`
- if you want broader on-access coverage, edit `/etc/clamav/onaccess.watch`
- if you want fewer exclusions, edit `/etc/clamav/onaccess.exclude`

## Bottom Line

This guide gives Ubuntu users:

- automatic signature updates
- a fast daemon-backed ClamAV setup
- a daily scheduled scan
- on-access scanning for common risky folders
- quarantine-on-detection
- predictable logs
- a single copy-paste installer command
