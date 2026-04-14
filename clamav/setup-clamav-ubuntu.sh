#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer with sudo:"
  echo "sudo bash setup-clamav-ubuntu.sh"
  exit 1
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  echo "Unable to determine the target desktop user."
  echo "Run as: sudo bash setup-clamav-ubuntu.sh from the user session you want to protect."
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

cat >/usr/local/bin/clamav-daily-scan <<SCAN
#!/usr/bin/env bash
set -uo pipefail

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
  find "${ACTIVE_SCAN_PATHS[@]}" \
    \( \
      -name node_modules -o \
      -name .git -o \
      -name .venv -o \
      -name __pycache__ -o \
      -name dist -o \
      -name build -o \
      -name target \
    \) -prune -o \
    -type f -readable -print0
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
