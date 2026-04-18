#!/usr/bin/env bash
#
# ubuntu-rdp.sh — Install, configure, and verify xrdp on Ubuntu 22.04/24.04 with GNOME
#
# Usage:
#   sudo ./ubuntu-rdp.sh          # Full install + verify
#   sudo ./ubuntu-rdp.sh install   # Install and configure only
#   sudo ./ubuntu-rdp.sh verify    # Verify existing setup only
#   sudo ./ubuntu-rdp.sh status    # Quick status check
#   sudo ./ubuntu-rdp.sh uninstall # Remove xrdp completely

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

ERRORS=0

# --- Root check ---
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root (use sudo).${NC}"
        exit 1
    fi
}

# --- Detect the real user (not root) ---
get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

# --- Install ---
do_install() {
    require_root
    local REAL_USER
    REAL_USER=$(get_real_user)
    local REAL_HOME
    REAL_HOME=$(eval echo "~$REAL_USER")

    header "Installing xrdp"

    if dpkg -l xrdp &>/dev/null; then
        info "xrdp is already installed"
    else
        info "Updating package lists..."
        apt-get update -qq
        info "Installing xrdp..."
        apt-get install -y -qq xrdp >/dev/null
        pass "xrdp installed"
    fi

    header "Configuring xrdp"

    # Add xrdp user to ssl-cert group
    if id -nG xrdp | grep -qw ssl-cert; then
        info "xrdp user already in ssl-cert group"
    else
        adduser xrdp ssl-cert
        pass "Added xrdp to ssl-cert group"
    fi

    # Create .xsessionrc for GNOME session
    local XSESSION_FILE="$REAL_HOME/.xsessionrc"
    cat > "$XSESSION_FILE" << 'XSESSION'
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
XSESSION
    chown "$REAL_USER:$REAL_USER" "$XSESSION_FILE"
    pass "Created $XSESSION_FILE"

    # Create polkit rules to suppress auth dialogs over RDP
    local POLKIT_DIR="/etc/polkit-1/rules.d"
    if [[ -d "$POLKIT_DIR" ]]; then
        cat > "$POLKIT_DIR/02-allow-colord.rules" << 'POLKIT'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.color-manager.create-device" ||
         action.id == "org.freedesktop.color-manager.create-profile" ||
         action.id == "org.freedesktop.color-manager.delete-device" ||
         action.id == "org.freedesktop.color-manager.delete-profile" ||
         action.id == "org.freedesktop.color-manager.modify-device" ||
         action.id == "org.freedesktop.color-manager.modify-profile") &&
        subject.isInGroup("users")) {
        return polkit.Result.YES;
    }
});
POLKIT
        pass "Created polkit rules for colord"
    else
        warn "Polkit rules.d directory not found — skipping colord rules"
    fi

    # Configure firewall if active
    if ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 3389/tcp
        pass "Firewall rule added for port 3389"
    else
        info "Firewall (ufw) is inactive — no rule needed"
    fi

    # Enable and start xrdp
    systemctl enable xrdp --now
    systemctl enable xrdp-sesman --now
    pass "xrdp services enabled and started"

    header "Installation Complete"
    local IP
    IP=$(hostname -I | awk '{print $1}')
    info "Connect via RDP to ${GREEN}${IP}:3389${NC}"
    info "Username: ${GREEN}${REAL_USER}${NC}"
    echo ""
}

# --- Verify ---
do_verify() {
    require_root
    local REAL_USER
    REAL_USER=$(get_real_user)
    local REAL_HOME
    REAL_HOME=$(eval echo "~$REAL_USER")

    header "Verifying xrdp Setup"
    ERRORS=0

    # 1. Package installed
    header "1. Package Check"
    if dpkg -l xrdp 2>/dev/null | grep -q "^ii"; then
        local VERSION
        VERSION=$(dpkg -l xrdp | awk '/^ii/{print $3}')
        pass "xrdp is installed (version: $VERSION)"
    else
        fail "xrdp is NOT installed"
        ((ERRORS++))
    fi

    # 2. Services running
    header "2. Service Status"
    for svc in xrdp xrdp-sesman; do
        if systemctl is-active --quiet "$svc"; then
            pass "$svc is running"
        else
            fail "$svc is NOT running"
            ((ERRORS++))
        fi
        if systemctl is-enabled --quiet "$svc"; then
            pass "$svc is enabled on boot"
        else
            fail "$svc is NOT enabled on boot"
            ((ERRORS++))
        fi
    done

    # 3. Port listening
    header "3. Network"
    if ss -tlnp | grep -q ':3389'; then
        pass "Port 3389 is listening"
    else
        fail "Port 3389 is NOT listening"
        ((ERRORS++))
    fi

    local IP
    IP=$(hostname -I | awk '{print $1}')
    info "Local IP: $IP"

    # 4. Firewall
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status | grep -q "3389"; then
            pass "Firewall allows port 3389"
        else
            fail "Firewall is active but port 3389 is NOT allowed"
            ((ERRORS++))
        fi
    else
        info "Firewall (ufw) is inactive — no restriction"
    fi

    # 5. SSL cert group
    header "4. Permissions"
    if id -nG xrdp 2>/dev/null | grep -qw ssl-cert; then
        pass "xrdp user is in ssl-cert group"
    else
        fail "xrdp user is NOT in ssl-cert group"
        ((ERRORS++))
    fi

    # 6. Session config
    header "5. Session Configuration"
    local XSESSION_FILE="$REAL_HOME/.xsessionrc"
    if [[ -f "$XSESSION_FILE" ]]; then
        if grep -q "XDG_CURRENT_DESKTOP=ubuntu:GNOME" "$XSESSION_FILE"; then
            pass "$XSESSION_FILE configured for GNOME"
        else
            warn "$XSESSION_FILE exists but may not be configured for GNOME"
        fi
    else
        fail "$XSESSION_FILE is missing — RDP sessions may get a blank screen"
        ((ERRORS++))
    fi

    # 7. startwm.sh
    if [[ -x /etc/xrdp/startwm.sh ]]; then
        pass "/etc/xrdp/startwm.sh is executable"
    else
        fail "/etc/xrdp/startwm.sh is missing or not executable"
        ((ERRORS++))
    fi

    # 8. Polkit rules
    header "6. Polkit Rules"
    if [[ -f /etc/polkit-1/rules.d/02-allow-colord.rules ]]; then
        pass "Colord polkit rules are in place"
    elif [[ -f /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla ]]; then
        pass "Colord polkit rules are in place (pkla format)"
    else
        warn "No colord polkit rules found — you may see auth dialogs on RDP"
    fi

    # 9. Connection test
    header "7. Connection Test"
    if command -v nc &>/dev/null; then
        if nc -z -w3 127.0.0.1 3389 2>/dev/null; then
            pass "TCP connection to localhost:3389 succeeded"
        else
            fail "TCP connection to localhost:3389 failed"
            ((ERRORS++))
        fi
    elif command -v bash &>/dev/null; then
        if (echo > /dev/tcp/127.0.0.1/3389) 2>/dev/null; then
            pass "TCP connection to localhost:3389 succeeded"
        else
            fail "TCP connection to localhost:3389 failed"
            ((ERRORS++))
        fi
    else
        warn "No connectivity tool available — skipping connection test"
    fi

    # 10. Recent logs
    header "8. Recent Logs"
    local LOG_ERRORS
    LOG_ERRORS=$(journalctl -u xrdp -u xrdp-sesman --since "10 min ago" --no-pager -p err 2>/dev/null | grep -v "^--" | tail -5)
    if [[ -z "$LOG_ERRORS" ]]; then
        pass "No recent errors in xrdp logs"
    else
        warn "Recent errors in xrdp logs:"
        echo "$LOG_ERRORS" | while read -r line; do
            echo -e "        $line"
        done
    fi

    # Summary
    header "Summary"
    if [[ $ERRORS -eq 0 ]]; then
        echo -e "  ${GREEN}All checks passed!${NC}"
        echo ""
        info "RDP is ready. Connect to ${GREEN}${IP}:3389${NC} with user ${GREEN}${REAL_USER}${NC}"
    else
        echo -e "  ${RED}${ERRORS} check(s) failed.${NC}"
        echo ""
        info "Run '${CYAN}sudo $0 install${NC}' to fix issues"
    fi
    echo ""
    return $ERRORS
}

# --- Status (quick, no root needed) ---
do_status() {
    header "xrdp Quick Status"
    if systemctl is-active --quiet xrdp 2>/dev/null; then
        pass "xrdp: running"
    else
        fail "xrdp: not running"
    fi
    if systemctl is-active --quiet xrdp-sesman 2>/dev/null; then
        pass "xrdp-sesman: running"
    else
        fail "xrdp-sesman: not running"
    fi
    if ss -tlnp 2>/dev/null | grep -q ':3389'; then
        pass "Port 3389: listening"
    else
        fail "Port 3389: not listening"
    fi
    local IP
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    info "IP: ${IP:-unknown}"
    echo ""
}

# --- Uninstall ---
do_uninstall() {
    require_root
    local REAL_USER
    REAL_USER=$(get_real_user)
    local REAL_HOME
    REAL_HOME=$(eval echo "~$REAL_USER")

    header "Uninstalling xrdp"

    systemctl stop xrdp xrdp-sesman 2>/dev/null || true
    systemctl disable xrdp xrdp-sesman 2>/dev/null || true
    apt-get remove --purge -y xrdp xorgxrdp 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    rm -f "$REAL_HOME/.xsessionrc"
    rm -f /etc/polkit-1/rules.d/02-allow-colord.rules
    rm -f /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla 2>/dev/null

    if ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow 3389/tcp 2>/dev/null || true
    fi

    pass "xrdp has been completely removed"
    echo ""
}

# --- Main ---
ACTION="${1:-all}"

case "$ACTION" in
    install)
        do_install
        ;;
    verify)
        do_verify
        ;;
    status)
        do_status
        ;;
    uninstall)
        do_uninstall
        ;;
    all)
        do_install
        do_verify
        ;;
    *)
        echo "Usage: sudo $0 {install|verify|status|uninstall|all}"
        exit 1
        ;;
esac
