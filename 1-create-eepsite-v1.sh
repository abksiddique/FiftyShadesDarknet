#!/bin/bash
# =============================================================================
# create-eepsite-v1.sh
# Script 1 of 4 — Exclusive Eepsite Toolkit
# "Invisible Within Invisible" — IEEE MILCOM 2026
#
# Author  : Siddique Abubakr Muntaka
# Advisor : Dr. Jacques Bou Abdo
# Lab     : MIRAGe-UC — University of Cincinnati
#
# PURPOSE:
#   Create a plain (no encryption) I2P eepsite by submitting I2P's own web
#   form — exactly as a human clicking in the browser would do.
#
# HOW THE I2P FORM ACTUALLY WORKS (confirmed from live HTML):
#   GET  /i2ptunnel/edit?type=httpserver  → returns form containing nonce
#   POST /i2ptunnel/list                  ← this is the form's action="list"
#        fields: tunnel=-1, nonce=<N>, type=httpserver, action=Save changes, ...
#   I2P saves config, starts tunnel, redirects back to /i2ptunnel/list.
#
# WHY PREVIOUS VERSIONS FAILED:
#   All previous scripts POSTed to /i2ptunnel/edit — WRONG.
#   The correct endpoint is /i2ptunnel/list (from form action="list").
#
# WHAT THIS SCRIPT DOES:
#   1. Auto-detects I2P installation (any location on the VM)
#   2. Prompts for domain name (any extension: .mil .i2p .darkest etc.)
#   3. Creates privKeyFile directory with correct ownership
#   4. Writes classified eepsite HTML to Jetty docroot
#   5. Fetches nonce from I2P edit form
#   6. POSTs to I2P form — creates the tunnel
#   7. Polls until tunnel appears in console
#   8. Polls until B32 address and full destination are available
#   9. Saves state file for Script 2 (customtld-manager)
#  10. Prints full summary with all addresses
#
# ENCRYPTION / ACCESS LIST:
#   None in this version. Plain open eepsite.
#   Encryption (LS2 PSK) is added in a later script once this works.
#
# USAGE:
#   sudo ./create-eepsite-v1.sh
#   sudo ./create-eepsite-v1.sh --domain sid.mil
#   sudo ./create-eepsite-v1.sh --domain sid.mil --diagnose
#
# REQUIRES: curl, openssl (for key dir), bash >= 4
# =============================================================================

set -euo pipefail

# ── Color codes ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC}    $*" >&2; }
log_ok()      { echo -e "${GREEN}[OK]${NC}      $*" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}" >&2; }
log_debug()   { [[ "$DIAGNOSE" == "yes" ]] && echo -e "${MAGENTA}[DEBUG]${NC}   $*" >&2 || true; }

# ── Globals (populated at runtime) ────────────────────────────────────────────
I2P_CONF_DIR=""        # e.g. /var/lib/i2p/i2p-config
I2P_USER=""            # e.g. i2psvc
I2P_PORT="7657"        # console port (read from router.config)
BASE_URL=""            # http://127.0.0.1:7657
TUNNEL_URL=""          # http://127.0.0.1:7657/i2ptunnel
CONF_D=""              # i2ptunnel.config.d directory
DOCROOT=""             # eepsite/docroot
STATE_DIR=""           # where we save state files

DOMAIN=""              # user-supplied domain
DIAGNOSE="no"          # --diagnose flag
ARG_DOMAIN=""          # --domain flag

# ── Parse arguments ────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)   ARG_DOMAIN="${2:-}"; shift 2 ;;
            --diagnose) DIAGNOSE="yes";      shift   ;;
            --help|-h)
                echo "Usage: sudo $0 [--domain <name>] [--diagnose]"
                echo "       sudo $0 --domain sid.mil"
                exit 0
                ;;
            *) shift ;;
        esac
    done
}

# ─── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && {
    echo -e "${RED}[ERROR]${NC}   Run with sudo: sudo $0 $*"
    exit 1
}

# =============================================================================
# STEP A: AUTO-DETECT I2P ENVIRONMENT
# Searches every common location. Falls back to filesystem find.
# =============================================================================
detect_i2p() {
    log_step "Auto-Detecting I2P Installation"

    local real_user="${SUDO_USER:-${USER:-}}"

    # Candidate directories in priority order
    local candidates=(
        "/var/lib/i2p/i2p-config"
        "/home/${real_user}/.i2p"
        "/root/.i2p"
        "${HOME}/.i2p"
        "/opt/i2p"
        "/opt/i2p/config"
    )

    for d in "${candidates[@]}"; do
        if [[ -n "$d" && -d "${d}/i2ptunnel.config.d" ]]; then
            I2P_CONF_DIR="$d"
            break
        fi
    done

    # Filesystem search fallback
    if [[ -z "$I2P_CONF_DIR" ]]; then
        log_info "Standard paths not found — searching filesystem (may take a moment)..."
        local found
        found=$(find /var /home /root /opt /srv -maxdepth 8 \
            -name "i2ptunnel.config.d" -type d 2>/dev/null | head -1 || true)
        if [[ -n "$found" ]]; then
            I2P_CONF_DIR=$(dirname "$found")
        fi
    fi

    if [[ -z "$I2P_CONF_DIR" ]]; then
        log_error "Cannot find I2P config directory."
        log_error "I2P must be installed and started at least once."
        log_error "Expected: a directory containing i2ptunnel.config.d/"
        exit 1
    fi
    log_ok "I2P config dir : $I2P_CONF_DIR"

    # Detect I2P user (owner of config dir)
    I2P_USER=$(stat -c '%U' "$I2P_CONF_DIR" 2>/dev/null || echo "")
    if [[ -z "$I2P_USER" || "$I2P_USER" == "root" ]]; then
        # Try process inspection
        I2P_USER=$(ps aux 2>/dev/null \
            | awk '/java.*i2p/{print $1}' \
            | grep -v root | head -1 || echo "")
    fi
    [[ -z "$I2P_USER" ]] && I2P_USER="i2psvc"
    log_ok "I2P user       : $I2P_USER"

    # Read actual console port from router.config
    local rcfg="${I2P_CONF_DIR}/router.config"
    if [[ -f "$rcfg" ]]; then
        local p
        p=$(grep -iE '^(consolePort|console\.port)\s*=' "$rcfg" 2>/dev/null \
            | grep -oE '[0-9]{4,5}' | head -1 || echo "")
        [[ -n "$p" ]] && I2P_PORT="$p"
    fi

    BASE_URL="http://127.0.0.1:${I2P_PORT}"
    TUNNEL_URL="${BASE_URL}/i2ptunnel"
    CONF_D="${I2P_CONF_DIR}/i2ptunnel.config.d"
    DOCROOT="${I2P_CONF_DIR}/eepsite/docroot"
    STATE_DIR="${I2P_CONF_DIR}/exclusive-eepsite-keys"

    log_ok "Console URL    : $TUNNEL_URL"
    log_ok "config.d       : $CONF_D"
    log_ok "Docroot        : $DOCROOT"
}

# =============================================================================
# STEP B: CHECK I2P IS RUNNING AND REACHABLE
# =============================================================================
check_i2p_running() {
    log_step "Checking I2P Console"

    if ! curl -sf --max-time 8 "${TUNNEL_URL}/list" > /dev/null 2>&1; then
        log_error "I2P console not reachable at: ${TUNNEL_URL}/list"
        log_error ""
        log_error "  Check if I2P is running:  sudo systemctl status i2p"
        log_error "  Start I2P:                sudo systemctl start i2p"
        log_error "  Then wait ~60 seconds for I2P to fully start."
        exit 1
    fi
    log_ok "I2P console is reachable"

    if command -v systemctl &>/dev/null && systemctl is-active --quiet i2p 2>/dev/null; then
        log_ok "I2P systemd service: active"
    fi
}

# =============================================================================
# STEP C: PROMPT FOR DOMAIN
# =============================================================================
prompt_domain() {
    log_step "Domain Configuration"
    echo ""
    echo -e "  Enter the domain name for your exclusive eepsite."
    echo -e "  Any extension is valid: ${BOLD}.i2p  .mil  .darkest  .covert  .onion${NC}"
    echo -e "  Examples:  ${CYAN}sid.mil${NC}   ${CYAN}alpha.darkest${NC}   ${CYAN}ops.covert${NC}   ${CYAN}secret.i2p${NC}"
    echo ""

    while true; do
        read -r -p "$(echo -e "  ${CYAN}Domain name${NC}: ")" DOMAIN
        DOMAIN="${DOMAIN// /}"   # strip spaces
        if [[ -z "$DOMAIN" ]]; then
            echo -e "  ${RED}Domain cannot be empty.${NC}"
        elif [[ ! "$DOMAIN" =~ \. ]]; then
            echo -e "  ${RED}Domain must contain a dot (e.g. sid.mil).${NC}"
        elif [[ "$DOMAIN" =~ [^a-zA-Z0-9._-] ]]; then
            echo -e "  ${RED}Invalid characters. Use letters, numbers, dots, hyphens only.${NC}"
        elif [[ ${#DOMAIN} -gt 63 ]]; then
            echo -e "  ${RED}Too long (max 63 chars).${NC}"
        else
            break
        fi
    done

    log_ok "Domain: $DOMAIN"
}

# =============================================================================
# CHECK DOMAIN DOES NOT ALREADY EXIST IN CONFIG
# =============================================================================
check_domain_free() {
    # Search config.d for a file already using this name
    local existing
    existing=$(grep -rl "^name=${DOMAIN}$" "${CONF_D}/" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        log_error "A tunnel named '${DOMAIN}' already exists:"
        log_error "  $existing"
        log_info  "Delete it via: ${TUNNEL_URL}/list"
        log_info  "Then remove:   rm -f \"${existing}\""
        exit 1
    fi

    # Also check the live console
    if curl -sf --max-time 8 "${TUNNEL_URL}/list" 2>/dev/null \
        | grep -q ">${DOMAIN}<\|title=\".*${DOMAIN}"; then
        log_error "Domain '${DOMAIN}' is already visible in I2P console."
        log_info  "Remove it via: ${TUNNEL_URL}/list"
        exit 1
    fi

    log_ok "Domain '${DOMAIN}' is free"
}

# =============================================================================
# CREATE PRIVKEYFILE DIRECTORY
# I2P generates eepPriv.dat here on first tunnel start.
# Path is stored relative to I2P_CONF_DIR in the config file.
# =============================================================================
setup_privkey_dir() {
    local safe
    safe=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
    PRIV_KEY_REL="eepsite-${safe}/eepPriv.dat"         # relative — used in config
    PRIV_KEY_DIR="${I2P_CONF_DIR}/eepsite-${safe}"     # absolute — for mkdir

    if [[ ! -d "$PRIV_KEY_DIR" ]]; then
        mkdir -p "$PRIV_KEY_DIR"
    fi
    chown "${I2P_USER}:${I2P_USER}" "$PRIV_KEY_DIR"
    chmod 700 "$PRIV_KEY_DIR"
    log_ok "privKeyFile dir: $PRIV_KEY_DIR  (relative: $PRIV_KEY_REL)"
}

# =============================================================================
# WRITE EEPSITE INDEX.HTML TO JETTY DOCROOT
# I2P's built-in Jetty serves files from eepsite/docroot on port 7658.
# The HTTP server tunnel points at 127.0.0.1:7658.
# =============================================================================
write_html() {
    if [[ ! -d "$DOCROOT" ]]; then
        log_warn "Docroot missing — creating: $DOCROOT"
        mkdir -p "$DOCROOT"
        chown "${I2P_USER}:${I2P_USER}" "$DOCROOT"
        chmod 755 "$DOCROOT"
    fi

    local tmpf
    tmpf=$(mktemp)
    cat > "$tmpf" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${DOMAIN}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #050510;
      color: #00ff41;
      font-family: 'Courier New', monospace;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .terminal {
      border: 1px solid #00ff41;
      padding: 2.5em;
      max-width: 720px;
      width: 90%;
      box-shadow: 0 0 40px rgba(0,255,65,0.12);
    }
    .header {
      color: #ff4500;
      font-size: 1.3em;
      font-weight: bold;
      border-bottom: 1px solid #ff4500;
      padding-bottom: 0.6em;
      margin-bottom: 1.2em;
    }
    .row { margin: 0.5em 0; font-size: 0.93em; }
    .label { color: #555; }
    .value { color: #00ff41; }
    .accent { color: #ffd700; font-weight: bold; }
    .footer {
      margin-top: 1.8em;
      padding-top: 0.8em;
      border-top: 1px solid #0d0d20;
      color: #1e1e3c;
      font-size: 0.76em;
      line-height: 1.7;
    }
  </style>
</head>
<body>
<div class="terminal">
  <div class="header">&#x1F512; EXCLUSIVE CHANNEL: ${DOMAIN}</div>
  <div class="row">
    <span class="label">Status    : </span>
    <span class="accent">AUTHORIZED ACCESS — ACTIVE</span>
  </div>
  <div class="row">
    <span class="label">Domain    : </span>
    <span class="value">${DOMAIN}</span>
  </div>
  <div class="row">
    <span class="label">Network   : </span>
    <span class="value">I2P Garlic Network</span>
  </div>
  <div class="row">
    <span class="label">Node      : </span>
    <span class="value">$(hostname 2>/dev/null || echo 'VM1')</span>
  </div>
  <div class="row">
    <span class="label">Timestamp : </span>
    <span class="value">$(date -u '+%Y-%m-%d %H:%M:%S UTC')</span>
  </div>
  <div class="footer">
    Invisible Within Invisible: Covert Communication in the Invisible Internet<br>
    IEEE MILCOM 2026 &nbsp;|&nbsp; MIRAGe-UC, University of Cincinnati<br>
    Siddique Abubakr Muntaka &nbsp;|&nbsp; Dr. Jacques Bou Abdo
  </div>
</div>
</body>
</html>
HTMLEOF

    mv "$tmpf" "${DOCROOT}/index.html"
    chown "${I2P_USER}:${I2P_USER}" "${DOCROOT}/index.html"
    chmod 644 "${DOCROOT}/index.html"
    log_ok "index.html written: ${DOCROOT}/index.html"
}

# =============================================================================
# FETCH NONCE FROM I2P EDIT FORM
#
# The nonce is a hidden field in the NEW SERVER form:
#   GET /i2ptunnel/edit?type=httpserver
#   → <input type="hidden" name="nonce" value="7129019846308615807" />
#
# This nonce is then submitted with the POST to /i2ptunnel/list.
# =============================================================================
get_edit_nonce() {
    local html
    html=$(curl -sf --max-time 10 "${TUNNEL_URL}/edit?type=httpserver" 2>/dev/null || echo "")

    if [[ -z "$html" ]]; then
        log_error "Could not fetch edit form from ${TUNNEL_URL}/edit?type=httpserver"
        exit 1
    fi

    log_debug "Edit form fetched (${#html} bytes)"

    # Extract nonce from hidden input field
    # Pattern: <input type="hidden" name="nonce" value="7129019846308615807" />
    # Using sed to avoid grep -o portability issues with special chars
    local nonce
    nonce=$(echo "$html" \
        | sed -n 's/.*name="nonce" value="\([^"]*\)".*/\1/p' | head -1 || echo "")

    # Alternate: value comes before name in attribute order
    if [[ -z "$nonce" ]]; then
        nonce=$(echo "$html" \
            | sed -n 's/.*value="\([0-9-][0-9]*\)" [^>]*name="nonce".*/\1/p' \
            | head -1 || echo "")
    fi

    # Last resort: grab any large integer from a value= attribute near "nonce"
    if [[ -z "$nonce" ]]; then
        nonce=$(echo "$html" \
            | grep -i 'nonce' \
            | grep -oE '[0-9]{10,}' | head -1 || echo "")
    fi

    if [[ -z "$nonce" ]]; then
        log_error "Could not extract nonce from I2P edit form."
        log_error "The edit form may have loaded incorrectly."
        if [[ "$DIAGNOSE" == "yes" ]]; then
            log_debug "Edit form HTML snippet:"
            echo "$html" | grep -i 'nonce|hidden' | head -10 >&2 || true
        fi
        exit 1
    fi

    log_ok "Nonce from edit form: $nonce"
    echo "$nonce"
}

# =============================================================================
# POST TO I2P FORM — CREATE THE TUNNEL
#
# CRITICAL:
#   - POST endpoint is /i2ptunnel/list  (NOT /i2ptunnel/edit)
#   - This is confirmed from the form HTML: <form method="post" action="list">
#   - The nonce comes from the EDIT form (fetched above)
#   - encryptMode=0 = no encryption (plain eepsite)
#   - startOnLoad=1 = auto-start when I2P starts
# =============================================================================
create_tunnel_via_form() {
    local nonce="$1"

    log_info "POSTing to: ${TUNNEL_URL}/list"
    log_info "Domain: ${DOMAIN}  |  Port: 7658  |  Encryption: none"

    if [[ "$DIAGNOSE" == "yes" ]]; then
        log_debug "Fields:"
        log_debug "  tunnel=-1  nonce=${nonce}  type=httpserver  action=Save changes"
        log_debug "  nofilter_name=${DOMAIN}  targetPort=7658  encryptMode=0"
        log_debug "  privKeyFile=${PRIV_KEY_REL}  spoofedHost=${DOMAIN}"
    fi

    local response
    response=$(curl -sf --max-time 30 \
        -X POST \
        "${TUNNEL_URL}/list" \
        --data-urlencode "tunnel=-1" \
        --data-urlencode "nonce=${nonce}" \
        --data-urlencode "type=httpserver" \
        --data-urlencode "action=Save changes" \
        --data-urlencode "nofilter_name=${DOMAIN}" \
        --data-urlencode "nofilter_description=Exclusive eepsite: ${DOMAIN} [IEEE MILCOM 2026]" \
        --data-urlencode "startOnLoad=1" \
        --data-urlencode "targetHost=127.0.0.1" \
        --data-urlencode "targetPort=7658" \
        --data-urlencode "spoofedHost=${DOMAIN}" \
        --data-urlencode "privKeyFile=${PRIV_KEY_REL}" \
        --data-urlencode "tunnelDepth=3" \
        --data-urlencode "tunnelVariance=0" \
        --data-urlencode "tunnelQuantity=2" \
        --data-urlencode "tunnelBackupQuantity=0" \
        --data-urlencode "encryptMode=0" \
        --data-urlencode "sigType=7" \
        --data-urlencode "encType=4" \
        --data-urlencode "accessMode=0" \
        --data-urlencode "profile=bulk" \
        --data-urlencode "limitMinute=30" \
        --data-urlencode "limitHour=80" \
        --data-urlencode "limitDay=200" \
        --data-urlencode "totalMinute=50" \
        --data-urlencode "totalHour=0" \
        --data-urlencode "totalDay=0" \
        --data-urlencode "maxStreams=30" \
        --data-urlencode "postMax=6" \
        --data-urlencode "postBanTime=20" \
        --data-urlencode "postTotalMax=20" \
        --data-urlencode "postTotalBanTime=10" \
        --data-urlencode "postCheckTime=5" \
        2>/dev/null || echo "")

    if [[ "$DIAGNOSE" == "yes" ]]; then
        log_debug "POST response (first 500 chars):"
        echo "${response:0:500}" || true
    fi

    # Check response for errors
    if echo "$response" | grep -qi "error\|exception\|invalid"; then
        log_warn "I2P returned a possible error in the response."
        if [[ "$DIAGNOSE" == "yes" ]]; then
            echo "$response" | grep -i "error\|exception\|invalid" | head -5 || true
        fi
    fi
}

# =============================================================================
# POLL UNTIL THE TUNNEL APPEARS IN THE LIST PAGE
# I2P saves the config and shows the tunnel almost immediately after POST.
# =============================================================================
wait_for_tunnel_in_list() {
    log_info "Polling ${TUNNEL_URL}/list for tunnel '${DOMAIN}'..."

    local max=60
    local elapsed=0

    while [[ $elapsed -lt $max ]]; do
        local html
        html=$(curl -sf --max-time 8 "${TUNNEL_URL}/list" 2>/dev/null || echo "")

        if echo "$html" | grep -q "${DOMAIN}"; then
            echo ""
            log_ok "Tunnel '${DOMAIN}' appeared in I2P console"
            return 0
        fi

        sleep 3
        elapsed=$(( elapsed + 3 ))
        printf "\r  ${CYAN}Waiting for tunnel to appear... %ds${NC}  " "$elapsed"
    done

    echo ""
    log_error "Tunnel '${DOMAIN}' did NOT appear in the console after ${max}s."
    log_error ""
    log_error "The POST likely did not register. Possible causes:"
    log_error "  1. The nonce was already used (stale). Try running the script again."
    log_error "  2. I2P rejected a required field."
    log_error "  3. I2P version changed form behavior."
    log_error ""
    log_error "Run with --diagnose for raw HTTP response:"
    log_error "  sudo $0 --domain ${DOMAIN} --diagnose"
    exit 1
}

# =============================================================================
# GET TUNNEL INDEX FROM THE LIST PAGE
# Format: href="edit?tunnel=8"  title="...sid.mil..."
# =============================================================================
get_tunnel_index() {
    local html
    html=$(curl -sf --max-time 8 "${TUNNEL_URL}/list" 2>/dev/null || echo "")

    local idx=""

    # Primary: find the edit link that contains our domain in its title attribute
    idx=$(echo "$html" \
        | grep -oE "edit\?tunnel=[0-9]+\"[^>]*title=\"[^\"]*${DOMAIN}" \
        | grep -oE 'tunnel=[0-9]+' | head -1 | sed 's/tunnel=//' || true)

    # Fallback: find domain text then look for nearest tunnel= reference
    if [[ -z "$idx" ]]; then
        idx=$(echo "$html" \
            | grep "${DOMAIN}" \
            | grep -oE 'tunnel=[0-9]+' | head -1 | sed 's/tunnel=//' || true)
    fi

    echo "$idx"
}

# =============================================================================
# START THE TUNNEL (if not already running)
# Uses the "Start" link from the list page.
# =============================================================================
start_tunnel_if_needed() {
    local tunnel_idx="$1"

    # Check if already running — running tunnels show a "Stop" action
    local html
    html=$(curl -sf --max-time 8 "${TUNNEL_URL}/list" 2>/dev/null || echo "")

    local is_running
    is_running=$(echo "$html" \
        | grep -A10 "${DOMAIN}" \
        | grep -c 'action=stop' || echo "0")

    if [[ "$is_running" -gt 0 ]]; then
        log_ok "Tunnel is already running"
        return 0
    fi

    # Need to start it — get nonce from list page
    local list_nonce
    list_nonce=$(echo "$html" \
        | grep -oE 'nonce=-?[0-9]+' | head -1 | sed 's/nonce=//' || echo "")

    if [[ -z "$list_nonce" ]]; then
        log_warn "Cannot extract nonce for start command — tunnel may start on its own"
        return 0
    fi

    log_info "Sending Start command (tunnel index: ${tunnel_idx})..."
    curl -sf --max-time 15 \
        "${TUNNEL_URL}/list?nonce=${list_nonce}&action=start&tunnel=${tunnel_idx}" \
        > /dev/null 2>/dev/null || true

    log_ok "Start command sent"
}

# =============================================================================
# WAIT FOR B32 AND FULL DESTINATION
#
# After the tunnel starts, I2P generates the destination keys (eepPriv.dat).
# The B32 address (52 chars + .b32.i2p) and the full base64 destination
# appear on the edit page for that tunnel index.
#
# This can take 1-5 minutes on first start while I2P builds tunnels.
# =============================================================================
wait_for_b32() {
    local tunnel_idx="$1"

    log_info "Waiting for I2P to generate destination keys..."
    log_info "(This can take 1-5 minutes on first start — I2P is building tunnels)"

    local b32=""
    local dest=""
    local max=300   # 5 minutes
    local elapsed=0

    while [[ $elapsed -lt $max ]]; do
        local edit_html
        edit_html=$(curl -sf --max-time 8 \
            "${TUNNEL_URL}/edit?tunnel=${tunnel_idx}" 2>/dev/null || echo "")

        # B32 address: 52+ lowercase base32 chars + .b32.i2p
        b32=$(echo "$edit_html" \
            | grep -oE '[a-z2-7]{52,}\.b32\.i2p' | head -1 || true)

        # Full destination: long base64 string (516+ chars)
        dest=$(echo "$edit_html" \
            | grep -oE '[A-Za-z0-9+/~=-]{516,}' | head -1 || true)

        if [[ -n "$b32" ]]; then
            echo ""
            log_ok "B32 address obtained: $b32"
            [[ -n "$dest" ]] && log_ok "Full destination obtained (${#dest} chars)"
            B32_ADDR="$b32"
            FULL_DEST="$dest"
            return 0
        fi

        sleep 10
        elapsed=$(( elapsed + 10 ))
        printf "\r  ${CYAN}Waiting for destination keys... %ds${NC}  " "$elapsed"
    done

    echo ""
    log_warn "B32 address not yet available after ${max}s."
    log_warn "I2P may still be building tunnels. Check manually:"
    log_warn "  ${TUNNEL_URL}/edit?tunnel=${tunnel_idx}"
    B32_ADDR="PENDING"
    FULL_DEST="PENDING"
}

# =============================================================================
# SAVE STATE FILE (for Script 2: customtld-manager)
# =============================================================================
save_state() {
    local tunnel_idx="$1"

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true

    local safe
    safe=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')

    # Find config file that was written by I2P after form submission
    local conf_file=""
    conf_file=$(grep -rl "^name=${DOMAIN}$" "${CONF_D}/" 2>/dev/null | head -1 || echo "")

    local state_file="${STATE_DIR}/${safe}.state"
    cat > "$state_file" << STATEEOF
# =============================================================================
# Eepsite State — ${DOMAIN}
# Created: $(date '+%Y-%m-%d %H:%M:%S')
# Use with Script 2: customtld-manager.sh add ${DOMAIN} \${FULL_DEST}
# =============================================================================
DOMAIN=${DOMAIN}
SAFE_NAME=${safe}
B32_ADDR=${B32_ADDR}
FULL_DEST=${FULL_DEST}
TUNNEL_INDEX=${tunnel_idx}
CONF_FILE=${conf_file}
I2P_CONF_DIR=${I2P_CONF_DIR}
I2P_USER=${I2P_USER}
PRIV_KEY_DIR=${PRIV_KEY_DIR}
PRIV_KEY_REL=${PRIV_KEY_REL}
DOCROOT=${DOCROOT}
CONSOLE_URL=${TUNNEL_URL}/list
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
STATEEOF

    chmod 600 "$state_file"
    log_ok "State file: $state_file"
    STATE_FILE="$state_file"
}

# =============================================================================
# VERIFY THE CONFIG FILE WAS WRITTEN BY I2P
# =============================================================================
verify_config_file() {
    local cf
    cf=$(grep -rl "^name=${DOMAIN}$" "${CONF_D}/" 2>/dev/null | head -1 || echo "")

    if [[ -n "$cf" ]]; then
        log_ok "Config file written by I2P: $cf"
        if [[ "$DIAGNOSE" == "yes" ]]; then
            log_debug "Config file contents:"
            cat "$cf"
        fi
    else
        log_warn "Config file not yet found in ${CONF_D}/"
        log_info  "I2P may write it asynchronously — check: ls ${CONF_D}/"
    fi
}

# =============================================================================
# PRINT FINAL SUMMARY
# =============================================================================
print_summary() {
    local tunnel_idx="$1"

    local conf_file
    conf_file=$(grep -rl "^name=${DOMAIN}$" "${CONF_D}/" 2>/dev/null | head -1 || echo "not found yet")

    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║              EEPSITE CREATED SUCCESSFULLY                           ║${NC}"
    echo -e "${BOLD}${MAGENTA}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${MAGENTA}║${NC}  Domain        : ${BOLD}${DOMAIN}${NC}"
    echo -e "${BOLD}${MAGENTA}║${NC}  B32 Address   : ${CYAN}${B32_ADDR}${NC}"
    echo -e "${BOLD}${MAGENTA}║${NC}  Tunnel Index  : ${tunnel_idx}"
    echo -e "${BOLD}${MAGENTA}║${NC}  Config File   : ${conf_file}"
    echo -e "${BOLD}${MAGENTA}║${NC}  privKeyFile   : ${PRIV_KEY_DIR}/eepPriv.dat"
    echo -e "${BOLD}${MAGENTA}║${NC}  Jetty target  : 127.0.0.1:7658"
    echo -e "${BOLD}${MAGENTA}║${NC}  Encryption    : None (plain eepsite)"
    echo -e "${BOLD}${MAGENTA}║${NC}  State File    : ${STATE_FILE:-not saved}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ -n "$FULL_DEST" && "$FULL_DEST" != "PENDING" ]]; then
        echo -e "${BOLD}Full Destination (for Script 2 / addressbook):${NC}"
        echo -e "  ${CYAN}${FULL_DEST}${NC}"
        echo ""
    fi

    echo -e "${BOLD}${YELLOW}NEXT STEPS:${NC}"
    echo ""
    echo -e "  ${BOLD}[1] Verify tunnel is running:${NC}"
    echo -e "      ${CYAN}${TUNNEL_URL}/list${NC}"
    echo ""
    echo -e "  ${BOLD}[2] Test the Jetty web server locally:${NC}"
    echo -e "      ${CYAN}curl http://127.0.0.1:7658/${NC}"
    echo ""
    echo -e "  ${BOLD}[3] If B32 is PENDING, get it after ~2-5 min:${NC}"
    echo -e "      ${CYAN}curl -s '${TUNNEL_URL}/edit?tunnel=${tunnel_idx}' | grep -o '[a-z2-7]*\\.b32\\.i2p'${NC}"
    echo ""
    echo -e "  ${BOLD}[4] Map domain to destination (Script 2 — run on VM1 AND VM2):${NC}"
    if [[ "$B32_ADDR" != "PENDING" ]]; then
        echo -e "      ${CYAN}sudo ./customtld-manager.sh add ${DOMAIN} <full-base64-destination>${NC}"
        echo -e "      ${YELLOW}(Use the Full Destination printed above, NOT the B32)${NC}"
    else
        echo -e "      Wait for B32, then get full destination from the edit page."
        echo -e "      ${CYAN}sudo ./customtld-manager.sh add ${DOMAIN} <full-base64-destination>${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}[5] To restart the tunnel anytime:${NC}"
    echo -e "      ${CYAN}sudo ./start-tunnel.sh ${DOMAIN}${NC}"
    echo ""
    echo -e "${YELLOW}NOTE:${NC} This eepsite is currently open (no access control)."
    echo -e "      Access list and encryption will be added in subsequent scripts."
    echo ""
}

# =============================================================================
# MAIN FLOW
# =============================================================================
main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║         I2P EXCLUSIVE EEPSITE CREATOR — Script 1 of 4              ║${NC}"
    echo -e "${BOLD}${MAGENTA}║         Invisible Within Invisible — IEEE MILCOM 2026               ║${NC}"
    echo -e "${BOLD}${MAGENTA}║         MIRAGe-UC — University of Cincinnati                        ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # A: Auto-detect I2P
    detect_i2p

    # B: Check I2P is running
    check_i2p_running

    # C: Get domain (from arg or prompt)
    if [[ -n "$ARG_DOMAIN" ]]; then
        DOMAIN="$ARG_DOMAIN"
        log_ok "Domain (from --domain flag): $DOMAIN"
    else
        prompt_domain
    fi

    # D: Check domain is free
    log_step "Checking Domain Availability"
    check_domain_free

    # E: Create privKeyFile directory
    log_step "Preparing Private Key Directory"
    setup_privkey_dir

    # F: Write eepsite HTML
    log_step "Writing Eepsite Content"
    write_html

    # G: Get nonce from I2P edit form
    log_step "Fetching I2P Form Nonce"
    NONCE=$(get_edit_nonce)

    # H: POST to I2P — create the tunnel
    log_step "Creating Tunnel via I2P Web Form"
    create_tunnel_via_form "$NONCE"

    # I: Poll until tunnel appears
    log_step "Waiting for Tunnel Registration"
    wait_for_tunnel_in_list

    # J: Get tunnel index
    log_step "Retrieving Tunnel Index"
    TUNNEL_IDX=$(get_tunnel_index)
    if [[ -z "$TUNNEL_IDX" ]]; then
        log_warn "Could not determine tunnel index automatically."
        log_info  "Find it manually: ${TUNNEL_URL}/list"
        TUNNEL_IDX="unknown"
    else
        log_ok "Tunnel index: $TUNNEL_IDX"
    fi

    # K: Start tunnel if needed
    if [[ "$TUNNEL_IDX" != "unknown" ]]; then
        log_step "Starting Tunnel"
        start_tunnel_if_needed "$TUNNEL_IDX"
    fi

    # L: Wait for B32 / destination keys
    log_step "Waiting for Destination Key Generation"
    B32_ADDR=""
    FULL_DEST=""
    if [[ "$TUNNEL_IDX" != "unknown" ]]; then
        wait_for_b32 "$TUNNEL_IDX"
    else
        B32_ADDR="PENDING"
        FULL_DEST="PENDING"
    fi

    # M: Verify config file
    log_step "Verifying Config File"
    verify_config_file

    # N: Save state
    log_step "Saving State File"
    save_state "${TUNNEL_IDX:-unknown}"

    # O: Print summary
    print_summary "${TUNNEL_IDX:-unknown}"
}

# ── Globals set in later functions ────────────────────────────────────────────
PRIV_KEY_REL=""
PRIV_KEY_DIR=""
B32_ADDR=""
FULL_DEST=""
STATE_FILE=""
TUNNEL_IDX=""
NONCE=""

main "$@"
