#!/bin/bash
# =============================================================================
# setup-i2p-proxy.sh — Script 2b of 4
# "Invisible Within Invisible" — IEEE MILCOM 2026
#
# Author  : Siddique Abubakr Muntaka
# Advisor : Dr. Jacques Bou Abdo
# Lab     : MIRAGe-UC — University of Cincinnati
#
# PURPOSE:
#   Create an I2P SOCKS5 proxy tunnel on port 4447.
#   SOCKS5 resolves ANY domain through NamingService — no .i2p hardcheck.
#   This is required for custom TLD routing (.mil .darkest .covert etc).
#
# WHY SOCKS5 (not HTTP proxy):
#   I2P's HTTP proxy (port 4444) has a hardcoded check:
#     if hostname.endsWith(".i2p") → route through I2P
#     else                         → send to clearnet outproxy
#   This check is in compiled Java bytecode — cannot be changed via config.
#   I2P's SOCKS5 proxy has NO such check — calls NamingService.lookup()
#   for any hostname. So sid002.mil → addressbook lookup → I2P routing ✓
#
# WHAT THIS SCRIPT DOES:
#   1. Auto-detects I2P install location (works on any VM)
#   2. Creates SOCKS5 tunnel config in i2ptunnel.config.d/
#   3. Reloads I2P tunnel manager via console
#   4. Verifies SOCKS5 port is listening
#   5. Generates a VM2 version of this script
#
# USAGE:
#   sudo ./setup-i2p-proxy.sh
#   sudo ./setup-i2p-proxy.sh --port 4447   (default)
#   sudo ./setup-i2p-proxy.sh --status
#   sudo ./setup-i2p-proxy.sh --remove
#
# REQUIRES: bash, curl, grep, sed, ss — all standard coreutils
# REPRODUCIBLE: Works on any Linux VM regardless of I2P install location
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}    $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}      $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}    $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
SOCKS_PORT="4447"
MODE="install"

# ── Globals ───────────────────────────────────────────────────────────────────
I2P_CONF_DIR=""
I2P_USER=""
I2P_PORT="7657"
I2P_I2CP_PORT="7654"
TUNNEL_URL=""
CONF_D=""
REAL_USER=""
REAL_HOME=""

# =============================================================================
# PARSE ARGS
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)   SOCKS_PORT="${2:-4447}"; shift 2 ;;
            --status) MODE="status";           shift   ;;
            --remove) MODE="remove";           shift   ;;
            --help|-h)
                echo "Usage: sudo $0 [--port 4447] [--status] [--remove]"
                exit 0 ;;
            *) shift ;;
        esac
    done
}

# =============================================================================
# ROOT CHECK
# =============================================================================
[[ $EUID -ne 0 ]] && {
    echo -e "${RED}[ERROR]${NC}   Run with sudo: sudo $0" >&2; exit 1
}

# =============================================================================
# DETECT REAL USER
# =============================================================================
detect_user() {
    REAL_USER="${SUDO_USER:-${USER:-}}"
    if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
        REAL_USER=$(who | awk '{print $1}' | head -1 || echo "")
    fi
    [[ -z "$REAL_USER" ]] && REAL_USER="sid"
    REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null \
        | cut -d: -f6 || echo "/home/${REAL_USER}")
    log_ok "User      : $REAL_USER"
    log_ok "Home      : $REAL_HOME"
}

# =============================================================================
# AUTO-DETECT I2P ENVIRONMENT
# Searches all common locations — works on any VM regardless of install method
# =============================================================================
detect_i2p() {
    log_step "Auto-Detecting I2P Installation"

    local candidates=(
        "${REAL_HOME}/.i2p"
        "/var/lib/i2p/i2p-config"
        "/home/${REAL_USER}/.i2p"
        "/root/.i2p"
        "${HOME}/.i2p"
        "/opt/i2p"
    )

    local d
    for d in "${candidates[@]}"; do
        if [[ -n "$d" && -d "${d}/i2ptunnel.config.d" ]]; then
            I2P_CONF_DIR="$d"
            break
        fi
    done

    # Filesystem search fallback
    if [[ -z "$I2P_CONF_DIR" ]]; then
        log_info "Searching filesystem for I2P config..."
        local found
        found=$(find /var /home /root /opt -maxdepth 8 \
            -name "i2ptunnel.config.d" -type d 2>/dev/null | head -1 || true)
        [[ -n "$found" ]] && I2P_CONF_DIR=$(dirname "$found")
    fi

    [[ -z "$I2P_CONF_DIR" ]] && {
        log_error "Cannot find I2P config directory."
        log_error "I2P must be installed and started at least once."
        exit 1
    }
    log_ok "I2P config : $I2P_CONF_DIR"

    # Detect I2P user (owner of config dir)
    I2P_USER=$(stat -c '%U' "$I2P_CONF_DIR" 2>/dev/null || echo "")
    if [[ -z "$I2P_USER" || "$I2P_USER" == "root" ]]; then
        I2P_USER=$(ps aux 2>/dev/null \
            | awk '/java.*i2p/{print $1}' \
            | grep -v root | head -1 || echo "")
    fi
    [[ -z "$I2P_USER" ]] && I2P_USER="$REAL_USER"
    log_ok "I2P user   : $I2P_USER"

    # Read actual ports from router.config
    local rcfg="${I2P_CONF_DIR}/router.config"
    if [[ -f "$rcfg" ]]; then
        local p
        p=$(grep -iE '^(consolePort|console\.port)\s*=' "$rcfg" 2>/dev/null \
            | grep -oE '[0-9]{4,5}' | head -1 || echo "")
        [[ -n "$p" ]] && I2P_PORT="$p"

        local ip
        ip=$(grep -iE '^(i2cpPort|i2cp\.port)\s*=' "$rcfg" 2>/dev/null \
            | grep -oE '[0-9]{4,5}' | head -1 || echo "")
        [[ -n "$ip" ]] && I2P_I2CP_PORT="$ip"
    fi

    TUNNEL_URL="http://127.0.0.1:${I2P_PORT}/i2ptunnel"
    CONF_D="${I2P_CONF_DIR}/i2ptunnel.config.d"

    log_ok "Console    : http://127.0.0.1:${I2P_PORT}"
    log_ok "I2CP port  : $I2P_I2CP_PORT"
    log_ok "config.d   : $CONF_D"
}

# =============================================================================
# CHECK I2P IS RUNNING
# =============================================================================
check_i2p() {
    if ! curl -sf --max-time 8 "${TUNNEL_URL}/list" > /dev/null 2>&1; then
        log_error "I2P console not reachable: ${TUNNEL_URL}/list"
        log_error "Start I2P first, wait ~60s, then run this script."
        exit 1
    fi
    log_ok "I2P console reachable"
}

# =============================================================================
# GET NEXT TUNNEL INDEX
# =============================================================================
next_tunnel_index() {
    local max=-1 idx f
    for f in "${CONF_D}"/[0-9]*-*-i2ptunnel.config; do
        [[ -f "$f" ]] || continue
        idx=$(basename "$f" | grep -oE '^[0-9]+' | sed 's/^0*//' || echo "")
        [[ -z "$idx" ]] && idx=0
        [[ "$idx" -gt "$max" ]] && max="$idx"
    done
    printf '%02d' $(( max + 1 ))
}

# =============================================================================
# CHECK IF SOCKS5 ALREADY EXISTS
# =============================================================================
socks_exists() {
    grep -rl "^type=sockstunnel$" "${CONF_D}/" 2>/dev/null \
        | head -1 | grep -q . && return 0 || return 1
}

get_socks_port() {
    local f
    f=$(grep -rl "^type=sockstunnel$" "${CONF_D}/" 2>/dev/null \
        | head -1 || echo "")
    [[ -z "$f" ]] && echo "" && return
    grep '^listenPort=' "$f" 2>/dev/null \
        | sed 's/^listenPort=//' | head -1 || echo ""
}

# =============================================================================
# RELOAD I2P TUNNEL MANAGER
# =============================================================================
reload_tunnels() {
    log_info "Reloading I2P tunnel manager..."

    local html nonce
    html=$(curl -sf --max-time 10 "${TUNNEL_URL}/list" 2>/dev/null || echo "")
    nonce=$(echo "$html" | grep -oE 'nonce=-?[0-9]+' \
        | head -1 | sed 's/nonce=//' || echo "")

    if [[ -n "$nonce" ]]; then
        curl -sf --max-time 20 \
            "${TUNNEL_URL}/list?nonce=${nonce}&action=Restart+all" \
            > /dev/null 2>&1 || true
        log_ok "Restart All sent to tunnel manager"
        log_info "Waiting 20s for tunnels to rebuild..."
        sleep 20
    else
        # Fallback: systemctl restart
        if command -v systemctl &>/dev/null \
           && systemctl is-active --quiet i2p 2>/dev/null; then
            log_info "Restarting I2P service via systemctl..."
            systemctl restart i2p
            log_ok "I2P restarted"
            log_info "Waiting 35s for I2P to come back online..."
            sleep 35
        else
            log_warn "Cannot auto-reload. Restart I2P manually."
            log_warn "Or visit: ${TUNNEL_URL}/list → Restart All"
        fi
    fi
}

# =============================================================================
# CREATE SOCKS5 TUNNEL CONFIG
#
# Written directly to i2ptunnel.config.d/ — same method used for eepsite
# creation (confirmed working in Script 1).
#
# type=sockstunnel — I2P's SOCKS4/4a/5 proxy type
# This proxy type calls NamingService.lookup() for ANY hostname.
# No hardcoded .i2p check — custom TLDs resolve correctly.
# =============================================================================
create_socks_tunnel() {
    log_step "Creating I2P SOCKS5 Tunnel"

    if socks_exists; then
        local existing_port
        existing_port=$(get_socks_port)
        log_ok "SOCKS5 tunnel already exists on port ${existing_port}"
        SOCKS_PORT="$existing_port"
        return 0
    fi

    # Check port availability
    if ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} "; then
        log_warn "Port ${SOCKS_PORT} already in use — trying $((SOCKS_PORT + 1))"
        SOCKS_PORT=$(( SOCKS_PORT + 1 ))
    fi

    local idx
    idx=$(next_tunnel_index)
    local conf_file="${CONF_D}/${idx}-I2P-SOCKS5-Proxy-i2ptunnel.config"

    log_info "Writing config: $conf_file"

    cat > "$conf_file" << SOCKSEOF
# NOTE: This I2P config file must use UTF-8 encoding
# I2P SOCKS5 Proxy — for custom TLD routing (.mil .darkest .covert etc)
# Created by setup-i2p-proxy.sh (Invisible Within Invisible — IEEE MILCOM 2026)
configFile=${conf_file}
description=SOCKS5 proxy for custom TLD routing (mil darkest covert etc)
i2cpHost=127.0.0.1
i2cpPort=${I2P_I2CP_PORT}
interface=127.0.0.1
listenPort=${SOCKS_PORT}
name=I2P SOCKS5 Proxy
option.i2cp.leaseSetEncType=6,4
option.i2cp.reduceIdleTime=900000
option.i2cp.reduceOnIdle=true
option.i2cp.reduceQuantity=1
option.inbound.length=3
option.inbound.lengthVariance=0
option.inbound.nickname=shared clients
option.outbound.length=3
option.outbound.lengthVariance=0
option.outbound.nickname=shared clients
sharedClient=true
startOnLoad=true
type=sockstunnel
SOCKSEOF

    chown "${I2P_USER}:${I2P_USER}" "$conf_file"
    chmod 600 "$conf_file"
    log_ok "Config written: $conf_file"
    log_ok "Port: $SOCKS_PORT"
}

# =============================================================================
# WAIT FOR SOCKS5 PORT TO START LISTENING
# =============================================================================
wait_for_socks() {
    log_info "Waiting for SOCKS5 port ${SOCKS_PORT} to start..."
    local max=90 elapsed=0

    while [[ $elapsed -lt $max ]]; do
        if ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} "; then
            echo "" >&2
            log_ok "SOCKS5 port ${SOCKS_PORT} is listening"
            return 0
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
        printf "\r  ${CYAN}Waiting for port ${SOCKS_PORT}... %ds${NC}  " \
            "$elapsed" >&2
    done

    echo "" >&2
    log_warn "Port ${SOCKS_PORT} not yet listening after ${max}s."
    log_warn "I2P may still be starting the tunnel."
    log_info "Check: ${TUNNEL_URL}/list"
    log_info "Or verify manually: ss -tlnp | grep ${SOCKS_PORT}"
}

# =============================================================================
# VERIFY WITH CURL
# =============================================================================
verify_socks() {
    log_info "Testing SOCKS5 with curl..."
    local result
    result=$(curl -sf --max-time 10 \
        --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
        "http://proxy.i2p/" 2>&1 | head -3 || echo "not yet ready")

    if echo "$result" | grep -qi "html\|i2p\|proxy"; then
        log_ok "SOCKS5 proxy responding correctly"
    else
        log_info "SOCKS5 tunnel may still be building — this is normal."
        log_info "Full test after patch-i2p-extension.sh + Firefox restart."
    fi
}

# =============================================================================
# GENERATE VM2 SCRIPT
# =============================================================================
generate_vm2_script() {
    local out_dir="${REAL_HOME}/Downloads"
    mkdir -p "$out_dir"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local script_path="${out_dir}/setup-i2p-proxy-vm2.sh"

    log_step "Generating VM2 Script"

    {
        cat << VM2HDR
#!/bin/bash
# =============================================================================
# setup-i2p-proxy-vm2.sh
# AUTO-GENERATED by setup-i2p-proxy.sh on VM1
# Generated : ${ts}
# SOCKS port: ${SOCKS_PORT}
# Paper     : Invisible Within Invisible — IEEE MILCOM 2026
# Author    : Siddique Abubakr Muntaka | MIRAGe-UC, Univ. of Cincinnati
#
# PURPOSE: Create I2P SOCKS5 tunnel on VM2 (same port as VM1).
# USAGE:   chmod +x setup-i2p-proxy-vm2.sh && sudo ./setup-i2p-proxy-vm2.sh
# =============================================================================

set -euo pipefail
VM2HDR

        echo "SOCKS_PORT=\"${SOCKS_PORT}\""
        echo "I2CP_PORT_DEFAULT=\"${I2P_I2CP_PORT}\""

        cat << 'VM2BODY'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC}    $*" >&2; }
log_ok()   { echo -e "${GREEN}[OK]${NC}      $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}    $*" >&2; }
log_error(){ echo -e "${RED}[ERROR]${NC}   $*" >&2; }
log_step() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}" >&2; }

[[ $EUID -ne 0 ]] && { echo "Run with sudo: sudo $0" >&2; exit 1; }

REAL_USER="${SUDO_USER:-${USER:-}}"
[[ -z "$REAL_USER" || "$REAL_USER" == "root" ]] && \
    REAL_USER=$(who | awk '{print $1}' | head -1 || echo "sid")
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null \
    | cut -d: -f6 || echo "/home/${REAL_USER}")

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     I2P SOCKS5 Proxy Setup for VM2                                 ║${NC}"
echo -e "${BOLD}${CYAN}║     Invisible Within Invisible — IEEE MILCOM 2026                  ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Detect I2P
log_step "Detecting I2P Installation"
I2P_CONF_DIR=""
for CAND in \
    "${REAL_HOME}/.i2p" \
    "/var/lib/i2p/i2p-config" \
    "/home/${REAL_USER}/.i2p" \
    "/root/.i2p" \
    "${HOME}/.i2p" \
    "/opt/i2p"; do
    if [[ -n "$CAND" && -d "${CAND}/i2ptunnel.config.d" ]]; then
        I2P_CONF_DIR="$CAND"; break
    fi
done

if [[ -z "$I2P_CONF_DIR" ]]; then
    FOUND=$(find /var /home /root /opt -maxdepth 8 \
        -name "i2ptunnel.config.d" -type d 2>/dev/null | head -1 || true)
    [[ -n "$FOUND" ]] && I2P_CONF_DIR=$(dirname "$FOUND")
fi

[[ -z "$I2P_CONF_DIR" ]] && {
    log_error "I2P config not found. Install and start I2P first."
    exit 1
}

I2P_USER=$(stat -c '%U' "$I2P_CONF_DIR" 2>/dev/null || echo "$REAL_USER")
[[ "$I2P_USER" == "root" || -z "$I2P_USER" ]] && I2P_USER="$REAL_USER"

RCFG="${I2P_CONF_DIR}/router.config"
I2P_PORT="7657"
I2CP_PORT="$I2CP_PORT_DEFAULT"
if [[ -f "$RCFG" ]]; then
    P=$(grep -iE '^(consolePort|console\.port)\s*=' "$RCFG" 2>/dev/null \
        | grep -oE '[0-9]{4,5}' | head -1 || echo "")
    [[ -n "$P" ]] && I2P_PORT="$P"
    IP=$(grep -iE '^(i2cpPort|i2cp\.port)\s*=' "$RCFG" 2>/dev/null \
        | grep -oE '[0-9]{4,5}' | head -1 || echo "")
    [[ -n "$IP" ]] && I2CP_PORT="$IP"
fi

TUNNEL_URL="http://127.0.0.1:${I2P_PORT}/i2ptunnel"
CONF_D="${I2P_CONF_DIR}/i2ptunnel.config.d"
log_ok "I2P config : $I2P_CONF_DIR"
log_ok "Console    : http://127.0.0.1:${I2P_PORT}"

# Check I2P running
curl -sf --max-time 8 "${TUNNEL_URL}/list" > /dev/null 2>&1 || {
    log_error "I2P not reachable. Start I2P and wait 60s first."
    exit 1
}
log_ok "I2P console reachable"

# Check if SOCKS5 already exists
EXISTING=$(grep -rl "^type=sockstunnel$" "${CONF_D}/" 2>/dev/null \
    | head -1 || echo "")
if [[ -n "$EXISTING" ]]; then
    EXISTING_PORT=$(grep '^listenPort=' "$EXISTING" 2>/dev/null \
        | sed 's/^listenPort=//' | head -1 || echo "$SOCKS_PORT")
    log_ok "SOCKS5 tunnel already exists on port ${EXISTING_PORT}"
    SOCKS_PORT="$EXISTING_PORT"
else
    # Get next tunnel index
    log_step "Creating SOCKS5 Tunnel"
    MAX=-1
    for F in "${CONF_D}"/[0-9]*-*-i2ptunnel.config; do
        [[ -f "$F" ]] || continue
        IDX=$(basename "$F" | grep -oE '^[0-9]+' | sed 's/^0*//' || echo "")
        [[ -z "$IDX" ]] && IDX=0
        [[ "$IDX" -gt "$MAX" ]] && MAX="$IDX"
    done
    IDX=$(printf '%02d' $(( MAX + 1 )))
    CONF_FILE="${CONF_D}/${IDX}-I2P-SOCKS5-Proxy-i2ptunnel.config"

    cat > "$CONF_FILE" << SOCKSEOF
# NOTE: This I2P config file must use UTF-8 encoding
configFile=${CONF_FILE}
description=SOCKS5 proxy for custom TLD routing
i2cpHost=127.0.0.1
i2cpPort=${I2CP_PORT}
interface=127.0.0.1
listenPort=${SOCKS_PORT}
name=I2P SOCKS5 Proxy
option.i2cp.leaseSetEncType=6,4
option.i2cp.reduceIdleTime=900000
option.i2cp.reduceOnIdle=true
option.i2cp.reduceQuantity=1
option.inbound.length=3
option.inbound.lengthVariance=0
option.inbound.nickname=shared clients
option.outbound.length=3
option.outbound.lengthVariance=0
option.outbound.nickname=shared clients
sharedClient=true
startOnLoad=true
type=sockstunnel
SOCKSEOF

    chown "${I2P_USER}:${I2P_USER}" "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    log_ok "Config: $CONF_FILE"

    # Reload tunnels
    HTML=$(curl -sf --max-time 10 "${TUNNEL_URL}/list" 2>/dev/null || echo "")
    NONCE=$(echo "$HTML" | grep -oE 'nonce=-?[0-9]+' \
        | head -1 | sed 's/nonce=//' || echo "")
    if [[ -n "$NONCE" ]]; then
        curl -sf --max-time 20 \
            "${TUNNEL_URL}/list?nonce=${NONCE}&action=Restart+all" \
            > /dev/null 2>&1 || true
        log_ok "Tunnel reload sent"
        sleep 20
    fi
fi

# Wait for port
log_step "Waiting for SOCKS5 Port ${SOCKS_PORT}"
ELAPSED=0
while [[ $ELAPSED -lt 90 ]]; do
    ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} " && {
        log_ok "Port ${SOCKS_PORT} is listening"
        break
    }
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
    printf "\r  Waiting... %ds" "$ELAPSED" >&2
done
echo "" >&2

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     SOCKS5 PROXY SETUP COMPLETE ON VM2                              ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  SOCKS5 port : ${BOLD}${SOCKS_PORT}${NC}"
echo ""
echo -e "${BOLD}Next step on VM2:${NC}"
echo -e "  Run the extension patcher:"
echo -e "  ${CYAN}sudo ./patch-i2p-extension-vm2.sh${NC}"
echo ""
VM2BODY

    } > "$script_path"

    chmod +x "$script_path"
    chown "${REAL_USER}:${REAL_USER}" "$script_path" 2>/dev/null || true
    log_ok "VM2 script: $script_path"
}

# =============================================================================
# STATUS
# =============================================================================
cmd_status() {
    log_step "SOCKS5 Proxy Status"
    echo ""

    echo -e "${BOLD}I2P:${NC}"
    if curl -sf --max-time 5 "${TUNNEL_URL}/list" > /dev/null 2>&1; then
        echo -e "  Console : ${GREEN}reachable${NC}"
    else
        echo -e "  Console : ${RED}not reachable${NC}"
    fi

    echo ""
    echo -e "${BOLD}SOCKS5 tunnel:${NC}"
    if socks_exists; then
        local p; p=$(get_socks_port)
        echo -e "  Config  : ${GREEN}exists${NC}"
        echo -e "  Port    : $p"
        if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
            echo -e "  Status  : ${GREEN}LISTENING${NC} ✓"
        else
            echo -e "  Status  : ${YELLOW}not yet listening${NC}"
        fi
    else
        echo -e "  Config  : ${RED}not found${NC}"
    fi
    echo ""
}

# =============================================================================
# REMOVE
# =============================================================================
cmd_remove() {
    log_step "Removing SOCKS5 Tunnel"
    local f
    for f in "${CONF_D}"/[0-9]*-*SOCKS*-i2ptunnel.config \
              "${CONF_D}"/[0-9]*-*socks*-i2ptunnel.config; do
        [[ -f "$f" ]] || continue
        rm -f "$f"
        log_ok "Removed: $f"
    done
    reload_tunnels
    log_ok "Done. SOCKS5 tunnel removed."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║     I2P SOCKS5 Proxy Setup — Script 2b of 4                        ║${NC}"
    echo -e "${BOLD}${MAGENTA}║     Invisible Within Invisible — IEEE MILCOM 2026                  ║${NC}"
    echo -e "${BOLD}${MAGENTA}║     MIRAGe-UC — University of Cincinnati                           ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log_step "Detecting Environment"
    detect_user
    detect_i2p

    case "$MODE" in
        status) check_i2p; cmd_status; return 0 ;;
        remove) check_i2p; cmd_remove; return 0 ;;
    esac

    check_i2p
    create_socks_tunnel
    reload_tunnels
    wait_for_socks
    verify_socks
    generate_vm2_script

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║     SOCKS5 PROXY SETUP COMPLETE                                     ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  I2P config  : $I2P_CONF_DIR"
    echo -e "  SOCKS5 port : ${BOLD}${SOCKS_PORT}${NC}"
    echo -e "  VM2 script  : ${REAL_HOME}/Downloads/setup-i2p-proxy-vm2.sh"
    echo ""
    echo -e "${BOLD}${YELLOW}NEXT STEPS:${NC}"
    echo ""
    echo -e "  ${BOLD}[1] Run the extension patcher:${NC}"
    echo -e "      ${CYAN}sudo ./patch-i2p-extension.sh${NC}"
    echo ""
    echo -e "  ${BOLD}[2] Restart Firefox completely.${NC}"
    echo ""
    echo -e "  ${BOLD}[3] Test in I2P private browsing tab:${NC}"
    echo -e "      Navigate to your eepsite domain"
    echo ""
    echo -e "  ${BOLD}[4] Copy VM2 script to VM2:${NC}"
    echo -e "      ${CYAN}scp ~/Downloads/setup-i2p-proxy-vm2.sh ${REAL_USER}@<VM2-IP>:~/Downloads/${NC}"
    echo ""
    echo -e "  ${BOLD}[5] Check status anytime:${NC}"
    echo -e "      ${CYAN}sudo ./setup-i2p-proxy.sh --status${NC}"
    echo ""
}

main "$@"
