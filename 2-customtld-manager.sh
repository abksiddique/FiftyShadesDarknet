#!/bin/bash
# =============================================================================
# customtld-manager.sh — Script 2 of 4
# "Invisible Within Invisible" — IEEE MILCOM 2026
#
# Author  : Siddique Abubakr Muntaka
# Advisor : Dr. Jacques Bou Abdo
# Lab     : MIRAGe-UC — University of Cincinnati
#
# PURPOSE:
#   Map an eepsite domain to its I2P destination in the PRIVATE addressbook.
#   Uses I2P's own susidns web form to add the entry — same as clicking Add
#   in the browser. No file manipulation, no reload step, works immediately.
#
# WHY PRIVATE ADDRESSBOOK:
#   Private entries are NEVER published to the I2P network.
#   Local entries ARE published — exposing your domain mappings publicly.
#   For covert/exclusive eepsites (military comms, journalists, research),
#   PRIVATE is always correct.
#
# WHY .i2p EXTENSION:
#   I2P's HTTP proxy (port 4444) only routes .i2p and .b32.i2p domains
#   through I2P. Any other TLD (.mil, .darkest, .covert) is sent to the
#   clearnet outproxy — bypassing I2P entirely. Use .i2p for all eepsites.
#
# WHAT THIS SCRIPT DOES:
#   1. Prompts for domain name (interactive) or takes it as argument
#   2. Parses full destination from eepPriv.dat (od+dd+base64+tr, no Python)
#   3. POSTs to /susidns/addressbook?book=private — I2P adds entry immediately
#   4. Verifies entry appears in the private addressbook
#   5. Auto-generates a ready-to-run VM2 installer script
#
# USAGE:
#   sudo ./customtld-manager.sh              <- interactive prompt
#   sudo ./customtld-manager.sh add sid12.i2p
#   sudo ./customtld-manager.sh add sid12.i2p <destination>  <- VM2
#   sudo ./customtld-manager.sh list
#   sudo ./customtld-manager.sh show sid12.i2p
#   sudo ./customtld-manager.sh remove sid12.i2p
#
# REQUIRES: bash, od, dd, base64, tr, curl, grep, sed — all standard coreutils
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# All log functions write to stderr — never pollutes $() captures
log_info()  { echo -e "${CYAN}[INFO]${NC}    $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}      $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}    $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}" >&2; }

# Globals
I2P_CONF_DIR=""; I2P_USER=""; I2P_PORT="7657"
SUSIDNS_URL=""; CONF_D=""; STATE_DIR=""
VM2_SCRIPT_PATH=""

# =============================================================================
# ROOT CHECK
# =============================================================================
[[ $EUID -ne 0 ]] && {
    echo -e "${RED}[ERROR]${NC}   Run with sudo: sudo $0" >&2; exit 1
}

# =============================================================================
# AUTO-DETECT I2P ENVIRONMENT
# =============================================================================
detect_i2p() {
    local real_user="${SUDO_USER:-${USER:-}}"
    local d
    for d in "/var/lib/i2p/i2p-config" \
             "/home/${real_user}/.i2p" \
             "/root/.i2p" \
             "${HOME}/.i2p" \
             "/opt/i2p"; do
        if [[ -n "$d" && -d "${d}/i2ptunnel.config.d" ]]; then
            I2P_CONF_DIR="$d"; break
        fi
    done

    if [[ -z "$I2P_CONF_DIR" ]]; then
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

    I2P_USER=$(stat -c '%U' "$I2P_CONF_DIR" 2>/dev/null || echo "")
    if [[ -z "$I2P_USER" || "$I2P_USER" == "root" ]]; then
        I2P_USER=$(ps aux 2>/dev/null \
            | awk '/java.*i2p/{print $1}' \
            | grep -v root | head -1 || echo "i2psvc")
    fi
    [[ -z "$I2P_USER" ]] && I2P_USER="i2psvc"

    # Read actual console port from router.config
    local rcfg="${I2P_CONF_DIR}/router.config"
    if [[ -f "$rcfg" ]]; then
        local p
        p=$(grep -iE '^(consolePort|console\.port)\s*=' "$rcfg" 2>/dev/null \
            | grep -oE '[0-9]{4,5}' | head -1 || echo "")
        [[ -n "$p" ]] && I2P_PORT="$p"
    fi

    SUSIDNS_URL="http://127.0.0.1:${I2P_PORT}/susidns"
    CONF_D="${I2P_CONF_DIR}/i2ptunnel.config.d"
    STATE_DIR="${I2P_CONF_DIR}/exclusive-eepsite-keys"

    log_ok "I2P config dir : $I2P_CONF_DIR"
    log_ok "I2P user       : $I2P_USER"
    log_ok "susidns URL    : $SUSIDNS_URL"
}

# =============================================================================
# CHECK I2P CONSOLE IS REACHABLE
# =============================================================================
check_i2p() {
    if ! curl -sf --max-time 8 "${SUSIDNS_URL}/index" > /dev/null 2>&1; then
        log_error "I2P console not reachable at: ${SUSIDNS_URL}"
        log_error "Start I2P: sudo systemctl start i2p"
        exit 1
    fi
    log_ok "I2P console reachable"
}

# =============================================================================
# PARSE DESTINATION FROM eepPriv.dat — PURE COREUTILS
#
# I2P Destination binary format:
#   [0:256]   Encryption public key (256 bytes)
#   [256:384] Signing public key    (128 bytes)
#   [384]     Certificate type      (1 byte)
#   [385:387] Certificate length    (2 bytes, big-endian)
#   [387:391] Certificate payload
#
# Addressbook format: base64 of destination bytes, with + -> - and / -> ~
# Tools: od, dd, base64, tr — GNU coreutils on every Linux distro
# =============================================================================
parse_dest_from_privkey() {
    local domain="$1"

    # Find tunnel config file
    local conf_file
    conf_file=$(grep -rl "^name=${domain}$" "${CONF_D}/" 2>/dev/null \
        | head -1 || echo "")
    if [[ -z "$conf_file" ]]; then
        log_warn "No config file for '${domain}' in ${CONF_D}/"
        return 1
    fi
    log_info "Config: $conf_file"

    # Read privKeyFile path (relative to I2P_CONF_DIR)
    local priv_rel
    priv_rel=$(grep '^privKeyFile=' "$conf_file" 2>/dev/null \
        | sed 's/^privKeyFile=//' | head -1 || echo "")
    [[ -z "$priv_rel" ]] && { log_warn "privKeyFile not set"; return 1; }

    local priv_abs
    if [[ "$priv_rel" = /* ]]; then
        priv_abs="$priv_rel"
    else
        priv_abs="${I2P_CONF_DIR}/${priv_rel}"
    fi
    log_info "privKeyFile: $priv_abs"

    if [[ ! -f "$priv_abs" ]]; then
        log_warn "eepPriv.dat not found: $priv_abs"
        log_warn "Tunnel must be RUNNING. Check the tunnel manager."
        log_warn "Wait 60s after starting, then retry."
        return 1
    fi

    local fsize
    fsize=$(stat -c '%s' "$priv_abs" 2>/dev/null || echo 0)
    log_info "eepPriv.dat: ${fsize} bytes"

    if [[ "$fsize" -lt 391 ]]; then
        log_warn "eepPriv.dat too small (${fsize} bytes). Wait and retry."
        return 1
    fi

    # Read cert length from bytes 385 (high) and 386 (low)
    local byte_hi byte_lo cert_len dest_end
    byte_hi=$(od -An -tu1 -j385 -N1 "$priv_abs" 2>/dev/null | tr -d ' \n')
    byte_lo=$(od -An -tu1 -j386 -N1 "$priv_abs" 2>/dev/null | tr -d ' \n')

    [[ -z "$byte_hi" || -z "$byte_lo" ]] && {
        log_warn "Cannot read cert length from eepPriv.dat"; return 1
    }

    cert_len=$(( byte_hi * 256 + byte_lo ))
    dest_end=$(( 384 + 3 + cert_len ))
    log_info "cert_len=${cert_len}  dest_end=${dest_end} bytes"

    [[ "$dest_end" -gt "$fsize" ]] && {
        log_warn "File truncated (need ${dest_end}, have ${fsize})"; return 1
    }

    # Extract bytes, base64 encode, convert to I2P addressbook format
    local dest
    dest=$(dd if="$priv_abs" bs=1 count="$dest_end" 2>/dev/null \
        | base64 | tr -d '\n' | tr '+' '-' | tr '/' '~')

    if [[ -z "$dest" || ${#dest} -lt 516 ]]; then
        log_warn "Destination too short: ${#dest} chars"; return 1
    fi

    log_ok "Destination parsed: ${#dest} chars"
    echo "$dest"
}

# =============================================================================
# READ DESTINATION FROM STATE FILE (from Script 1)
# =============================================================================
read_dest_from_state() {
    local domain="$1"
    local safe
    safe=$(echo "$domain" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9._-]/-/g')
    local sf="${STATE_DIR}/${safe}.state"
    [[ ! -f "$sf" ]] && sf="${STATE_DIR}/${domain}.state"
    [[ ! -f "$sf" ]] && { echo ""; return 0; }
    local dest
    dest=$(grep '^FULL_DEST=' "$sf" 2>/dev/null \
        | sed 's/^FULL_DEST=//' | head -1 || echo "")
    if [[ "$dest" == "PENDING" || -z "$dest" || ${#dest} -lt 516 ]]; then
        echo ""; return 0
    fi
    log_ok "Destination from state file (${#dest} chars)"
    echo "$dest"
}

# =============================================================================
# ADD ENTRY VIA SUSIDNS WEB FORM — WITH SESSION COOKIE
#
# susidns uses JSESSIONID cookie + serial token for CSRF protection.
# Both the GET (to fetch serial) and POST (to add entry) must use the
# SAME session cookie. We use a curl cookie jar to maintain the session.
#
# Confirmed working fields (from live HTML inspection):
#   book=private, serial=<from GET>, begin=0, end=49,
#   action=Add, hostname=<domain>, destination=<base64>
# =============================================================================
add_via_susidns() {
    local domain="$1"
    local dest="$2"

    log_info "Fetching susidns session and serial..."

    # Create a temporary cookie jar
    local cookie_jar
    cookie_jar=$(mktemp /tmp/i2p_susidns_XXXXXX.jar)

    # GET the addressbook page — saves session cookie, extracts serial
    local page serial
    page=$(curl -sf --max-time 15         -c "$cookie_jar"         "${SUSIDNS_URL}/addressbook?book=private&filter=none"         2>/dev/null || echo "")

    if [[ -z "$page" ]]; then
        rm -f "$cookie_jar"
        log_error "Cannot reach susidns addressbook page."
        return 1
    fi

    serial=$(echo "$page"         | grep -oE '"serial" value="[^"]*"'         | head -1 | sed 's/"serial" value="//;s/"//')

    if [[ -z "$serial" ]]; then
        rm -f "$cookie_jar"
        log_error "Cannot extract serial from susidns page."
        return 1
    fi
    log_info "Serial: $serial"

    # POST using the SAME session cookie
    local response
    response=$(curl -sf --max-time 20         -b "$cookie_jar" -c "$cookie_jar"         -X POST "${SUSIDNS_URL}/addressbook"         --data-urlencode "book=private"         --data-urlencode "serial=${serial}"         --data-urlencode "begin=0"         --data-urlencode "end=49"         --data-urlencode "action=Add"         --data-urlencode "hostname=${domain}"         --data-urlencode "destination=${dest}"         2>/dev/null || echo "CURL_FAILED")

    rm -f "$cookie_jar"

    if [[ "$response" == "CURL_FAILED" ]]; then
        log_error "curl POST to susidns failed."
        return 1
    fi

    # Check response for success/failure messages
    if echo "$response" | grep -qi "added\|saved"; then
        log_ok "susidns: entry added and address book saved"
        return 0
    elif echo "$response" | grep -qi "Invalid form"; then
        log_error "susidns: session cookie mismatch — CSRF check failed."
        return 1
    elif echo "$response" | grep -qi "already\|exist"; then
        log_warn "susidns: entry already exists for ${domain}"
        return 0
    else
        log_warn "susidns: unexpected response (entry may still have been added)"
        return 0
    fi
}

# =============================================================================
# VERIFY ENTRY IN PRIVATE ADDRESSBOOK
# Fetches the private addressbook page and checks domain appears
# =============================================================================
verify_in_addressbook() {
    local domain="$1"

    log_info "Verifying entry in private addressbook..."
    local page
    page=$(curl -sf --max-time 10 \
        "${SUSIDNS_URL}/addressbook?book=private&filter=none" \
        2>/dev/null || echo "")

    if echo "$page" | grep -q "$domain"; then
        log_ok "Entry verified: '$domain' found in private addressbook"
        return 0
    fi

    # Also check the actual privatehosts.txt file as backup
    local ab_conf="${I2P_CONF_DIR}/addressbook/config.txt"
    local priv_file=""
    if [[ -f "$ab_conf" ]]; then
        local priv_rel
        priv_rel=$(grep '^private_addressbook=' "$ab_conf" 2>/dev/null \
            | sed 's/^private_addressbook=//' | head -1 || echo "")
        if [[ -n "$priv_rel" ]]; then
            if [[ "$priv_rel" = /* ]]; then
                priv_file="$priv_rel"
            else
                priv_file="${I2P_CONF_DIR}/addressbook/${priv_rel}"
                # Handle ../ in path
                priv_file=$(realpath -m "$priv_file" 2>/dev/null || echo "$priv_file")
            fi
        fi
    fi
    [[ -z "$priv_file" ]] && priv_file="${I2P_CONF_DIR}/privatehosts.txt"

    if [[ -f "$priv_file" ]] && grep -q "^${domain}=" "$priv_file" 2>/dev/null; then
        log_ok "Entry verified in file: $priv_file"
        return 0
    fi

    log_warn "Could not verify entry in addressbook page or file."
    log_warn "It may still be active — I2P processes entries asynchronously."
    return 0
}

# =============================================================================
# REMOVE ENTRY VIA SUSIDNS
# =============================================================================
remove_via_susidns() {
    local domain="$1"

    log_info "Removing '${domain}' from private addressbook..."
    local response
    response=$(curl -sf --max-time 20 -X POST \
        "${SUSIDNS_URL}/addressbook?book=private&filter=none" \
        --data-urlencode "action=delete" \
        --data-urlencode "hostname=${domain}" \
        2>/dev/null || echo "CURL_FAILED")

    if [[ "$response" == "CURL_FAILED" ]]; then
        log_warn "curl failed — trying direct file removal..."
        # Fallback: remove from file directly
        local ab_conf="${I2P_CONF_DIR}/addressbook/config.txt"
        local priv_file="${I2P_CONF_DIR}/privatehosts.txt"
        if [[ -f "$ab_conf" ]]; then
            local rel
            rel=$(grep '^private_addressbook=' "$ab_conf" 2>/dev/null \
                | sed 's/^private_addressbook=//' | head -1 || echo "")
            [[ -n "$rel" ]] && priv_file="${I2P_CONF_DIR}/addressbook/${rel}"
            priv_file=$(realpath -m "$priv_file" 2>/dev/null || echo "$priv_file")
        fi
        if [[ -f "$priv_file" ]]; then
            sed -i "/^${domain}=/d" "$priv_file"
            log_ok "Removed from file: $priv_file"
        fi
        return 0
    fi

    log_ok "Remove command sent to susidns"
}

# =============================================================================
# GENERATE VM2 INSTALLER SCRIPT
# Self-contained, destination embedded. SCP to VM2 and run — no args needed.
# Uses same susidns POST approach so it works on VM2 regardless of file paths.
# =============================================================================
generate_vm2_script() {
    local domain="$1"
    local dest="$2"
    local safe="$3"
    local dest_len="${#dest}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    local real_user="${SUDO_USER:-${USER:-}}"
    local out_dir="${STATE_DIR}"
    [[ -d "/home/${real_user}/Downloads" ]] \
        && out_dir="/home/${real_user}/Downloads"
    mkdir -p "$out_dir"

    local script_name="install-${safe}-vm2.sh"
    VM2_SCRIPT_PATH="${out_dir}/${script_name}"

    log_step "Generating VM2 Installer Script"
    log_info "Script: $VM2_SCRIPT_PATH"
    log_info "Embedding destination: ${dest_len} chars"

    {
        # Header section — variables expanded from VM1 context
        cat << VM2HEADER
#!/bin/bash
# =============================================================================
# ${script_name}
# AUTO-GENERATED by customtld-manager.sh on VM1
# =============================================================================
# Domain      : ${domain}
# Dest length : ${dest_len} chars (embedded — do not edit)
# Generated   : ${ts} on VM1
# Paper       : Invisible Within Invisible — IEEE MILCOM 2026
# Author      : Siddique Abubakr Muntaka
# Lab         : MIRAGe-UC, University of Cincinnati
#
# PURPOSE:
#   Add '${domain}' to VM2's PRIVATE I2P addressbook.
#   Run on VM2 — no arguments needed. Destination is already embedded.
#
# USAGE:
#   chmod +x ${script_name}
#   sudo ./${script_name}
#
# AFTER RUNNING:
#   Configure your browser to use I2P proxy: 127.0.0.1:4444
#   Then browse to: http://${domain}/
# =============================================================================

set -euo pipefail

VM2HEADER

        # Literal section — no variable expansion (single-quoted delimiter)
        cat << 'VM2BODY'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}    $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}      $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}    $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}" >&2; }

[[ $EUID -ne 0 ]] && { echo "Run with sudo: sudo $0" >&2; exit 1; }

VM2BODY

        # Embed the actual destination values
        echo "DOMAIN=\"${domain}\""
        echo "DESTINATION=\"${dest}\""
        echo "DEST_LEN=\"${dest_len}\""
        echo "I2P_PORT=\"7657\""

        # Rest of VM2 script — literal, no expansion
        cat << 'VM2MAIN'

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     VM2 Private Addressbook Installer                               ║${NC}"
echo -e "${BOLD}${CYAN}║     Invisible Within Invisible — IEEE MILCOM 2026                  ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Domain      : ${BOLD}${DOMAIN}${NC}"
echo -e "  Destination : ${DEST_LEN} chars (embedded from VM1)"
echo ""

# ── Auto-detect I2P on VM2 ────────────────────────────────────────────────────
log_step "Auto-Detecting I2P Installation"
I2P_CONF_DIR=""
REAL_USER="${SUDO_USER:-${USER:-}}"

for CAND in "/var/lib/i2p/i2p-config" \
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

# Read actual console port
RCFG="${I2P_CONF_DIR}/router.config"
if [[ -f "$RCFG" ]]; then
    P=$(grep -iE '^(consolePort|console\.port)\s*=' "$RCFG" 2>/dev/null \
        | grep -oE '[0-9]{4,5}' | head -1 || echo "")
    [[ -n "$P" ]] && I2P_PORT="$P"
fi

SUSIDNS_URL="http://127.0.0.1:${I2P_PORT}/susidns"
log_ok "I2P config : $I2P_CONF_DIR"
log_ok "susidns    : $SUSIDNS_URL"

# ── Check I2P is running ───────────────────────────────────────────────────────
log_step "Checking I2P Console"
if ! curl -sf --max-time 8 "${SUSIDNS_URL}/index" > /dev/null 2>&1; then
    log_error "I2P console not reachable."
    log_error "Start I2P: sudo systemctl start i2p"
    log_error "Wait 60s for I2P to fully start, then run this script again."
    exit 1
fi
log_ok "I2P console reachable"

# ── Add to private addressbook via susidns ────────────────────────────────────
log_step "Adding to Private Addressbook"
log_info "POSTing to: ${SUSIDNS_URL}/addressbook?book=private"

# Use cookie jar — susidns requires session cookie + serial (CSRF protection)
COOKIE_JAR=$(mktemp /tmp/i2p_susidns_XXXXXX.jar)

PAGE=$(curl -sf --max-time 15 -c "$COOKIE_JAR" \
    "${SUSIDNS_URL}/addressbook?book=private&filter=none" \
    2>/dev/null || echo "")

[[ -z "$PAGE" ]] && {
    rm -f "$COOKIE_JAR"
    log_error "Cannot reach susidns. Is I2P running?"
    exit 1
}

SERIAL=$(echo "$PAGE" | grep -oE '"serial" value="[^"]*"' \
    | head -1 | sed 's/"serial" value="//;s/"//')
log_info "Serial: $SERIAL"

RESPONSE=$(curl -sf --max-time 20 \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -X POST "${SUSIDNS_URL}/addressbook" \
    --data-urlencode "book=private" \
    --data-urlencode "serial=${SERIAL}" \
    --data-urlencode "begin=0" \
    --data-urlencode "end=49" \
    --data-urlencode "action=Add" \
    --data-urlencode "hostname=${DOMAIN}" \
    --data-urlencode "destination=${DESTINATION}" \
    2>/dev/null || echo "CURL_FAILED")

rm -f "$COOKIE_JAR"

if [[ "$RESPONSE" == "CURL_FAILED" ]]; then
    log_error "Failed to POST to susidns."
    exit 1
fi

if echo "$RESPONSE" | grep -qi "added\|saved"; then
    log_ok "Entry added and address book saved"
elif echo "$RESPONSE" | grep -qi "already\|exist"; then
    log_warn "Entry already exists for ${DOMAIN}"
else
    log_warn "Unexpected response — entry may still have been added"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
log_step "Verifying Entry"
sleep 2

VERIFY=$(curl -sf --max-time 10 \
    "${SUSIDNS_URL}/addressbook?book=private&filter=none" \
    2>/dev/null || echo "")

if echo "$VERIFY" | grep -q "$DOMAIN"; then
    log_ok "VERIFIED: '${DOMAIN}' found in private addressbook"
else
    log_warn "Could not verify via page — checking file directly..."
    AB_CONF="${I2P_CONF_DIR}/addressbook/config.txt"
    PRIV_FILE="${I2P_CONF_DIR}/privatehosts.txt"
    if [[ -f "$AB_CONF" ]]; then
        REL=$(grep '^private_addressbook=' "$AB_CONF" 2>/dev/null \
            | sed 's/^private_addressbook=//' | head -1 || echo "")
        if [[ -n "$REL" ]]; then
            if [[ "$REL" = /* ]]; then
                PRIV_FILE="$REL"
            else
                PRIV_FILE=$(realpath -m \
                    "${I2P_CONF_DIR}/addressbook/${REL}" 2>/dev/null \
                    || echo "${I2P_CONF_DIR}/privatehosts.txt")
            fi
        fi
    fi
    if [[ -f "$PRIV_FILE" ]] && grep -q "^${DOMAIN}=" "$PRIV_FILE" 2>/dev/null; then
        log_ok "VERIFIED: '${DOMAIN}' found in $PRIV_FILE"
    else
        log_warn "Cannot verify — entry may still be processing."
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     VM2 ADDRESSBOOK ENTRY INSTALLED SUCCESSFULLY                    ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Domain      : ${BOLD}${DOMAIN}${NC}"
echo -e "  Addressbook : Private (never published)"
echo -e "  Dest length : ${DEST_LEN} chars"
echo ""
echo -e "${BOLD}Test access on VM2:${NC}"
echo -e "  Configure browser proxy: 127.0.0.1:4444"
echo -e "  Then browse to: ${CYAN}http://${DOMAIN}/${NC}"
echo ""
echo -e "${BOLD}Or test via curl:${NC}"
echo -e "  ${CYAN}curl --proxy http://127.0.0.1:4444 http://${DOMAIN}/${NC}"
echo ""
VM2MAIN

    } > "$VM2_SCRIPT_PATH"

    chmod +x "$VM2_SCRIPT_PATH"
    chown "${real_user}:${real_user}" "$VM2_SCRIPT_PATH" 2>/dev/null || true

    log_ok "VM2 script: $VM2_SCRIPT_PATH"
    log_ok "Destination embedded: ${dest_len} chars"
}

# =============================================================================
# CMD: ADD
# =============================================================================
cmd_add() {
    local domain="${1:-}"
    local dest_arg="${2:-}"

    # Interactive prompt if no domain given
    if [[ -z "$domain" ]]; then
        log_step "Domain Configuration"
        echo "" >&2
        echo -e "  Enter the eepsite domain name to add to the addressbook." >&2
        echo -e "  ${BOLD}Use .i2p extension${NC} — I2P proxy only routes .i2p domains." >&2
        echo -e "  Examples: ${CYAN}sid12.i2p${NC}  ${CYAN}ops.i2p${NC}  ${CYAN}alpha.i2p${NC}" >&2
        echo "" >&2
        while true; do
            read -r -p "$(echo -e "  ${CYAN}Domain name${NC}: ")" domain
            domain="${domain// /}"
            if [[ -z "$domain" ]]; then
                echo -e "  ${RED}Domain cannot be empty.${NC}" >&2
            elif [[ ! "$domain" =~ \. ]]; then
                echo -e "  ${RED}Must contain a dot (e.g. sid12.i2p).${NC}" >&2
            elif [[ "$domain" =~ [^a-zA-Z0-9._-] ]]; then
                echo -e "  ${RED}Invalid characters.${NC}" >&2
            elif [[ ! "$domain" =~ \.i2p$ ]]; then
                echo -e "  ${YELLOW}Warning: '${domain}' does not end in .i2p${NC}" >&2
                echo -e "  ${YELLOW}I2P proxy only routes .i2p domains.${NC}" >&2
                echo -e "  ${YELLOW}Custom TLDs (.mil .darkest etc) will NOT work.${NC}" >&2
                read -r -p "$(echo -e "  ${CYAN}Continue anyway? [y/N]:${NC} ")" yn
                [[ "$yn" =~ ^[Yy] ]] && break
            else
                break
            fi
        done
        log_ok "Domain: $domain"
    fi

    log_step "Adding to Private Addressbook"
    log_info "Domain: $domain"

    check_i2p

    # Get destination
    local dest=""
    if [[ -n "$dest_arg" ]]; then
        dest="$dest_arg"
        log_info "Using destination from argument"
    else
        log_step "Finding Destination"
        dest=$(read_dest_from_state "$domain")
        if [[ -z "$dest" ]]; then
            log_info "Parsing from eepPriv.dat..."
            dest=$(parse_dest_from_privkey "$domain" || echo "")
        fi
        if [[ -z "$dest" ]]; then
            log_error "Cannot obtain destination for '${domain}'."
            log_error ""
            log_error "  1. Ensure tunnel is RUNNING in the tunnel manager"
            log_error "     Wait 60s then retry: sudo $0 add ${domain}"
            log_error ""
            log_error "  2. Or provide destination manually:"
            log_error "     sudo $0 add ${domain} <base64-destination>"
            exit 1
        fi
    fi

    # Validate length
    if [[ ${#dest} -lt 516 ]]; then
        log_error "Destination too short: ${#dest} chars (need 516+)"
        log_error "Use the FULL base64 destination, not the B32 address."
        exit 1
    fi
    log_ok "Destination valid: ${#dest} chars"

    # Add via susidns web form
    log_step "Adding via I2P Naming Service"
    add_via_susidns "$domain" "$dest"

    # Wait a moment then verify
    sleep 2
    verify_in_addressbook "$domain"

    # Update state file if on VM1
    local safe
    safe=$(echo "$domain" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9._-]/-/g')
    local sf="${STATE_DIR}/${safe}.state"
    [[ -f "$sf" ]] && \
        sed -i "s|^FULL_DEST=.*|FULL_DEST=${dest}|" "$sf" 2>/dev/null || true

    # Generate VM2 installer script
    generate_vm2_script "$domain" "$dest" "$safe"

    # Summary
    local real_user="${SUDO_USER:-${USER:-}}"
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║     PRIVATE ADDRESSBOOK ENTRY ADDED SUCCESSFULLY                    ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Domain      : ${BOLD}${domain}${NC}"
    echo -e "  Addressbook : Private (never published to I2P network)"
    echo -e "  Dest length : ${#dest} chars"
    echo -e "  VM2 Script  : ${BOLD}${VM2_SCRIPT_PATH}${NC}"
    echo ""
    echo -e "${BOLD}${YELLOW}━━━ NEXT STEPS ━━━${NC}"
    echo ""
    echo -e "  ${BOLD}[1] Test on VM1 (browser proxy must be 127.0.0.1:4444):${NC}"
    echo -e "      Open: ${CYAN}http://${domain}/${NC}"
    echo -e "      Or:   ${CYAN}curl --proxy http://127.0.0.1:4444 http://${domain}/${NC}"
    echo ""
    echo -e "  ${BOLD}[2] Transfer VM2 installer to VM2:${NC}"
    echo -e "      ${CYAN}scp ${VM2_SCRIPT_PATH} ${real_user}@<VM2-IP>:~/Downloads/${NC}"
    echo ""
    echo -e "  ${BOLD}[3] On VM2 — run installer (no arguments needed):${NC}"
    echo -e "      ${CYAN}chmod +x $(basename ${VM2_SCRIPT_PATH})${NC}"
    echo -e "      ${CYAN}sudo ./$(basename ${VM2_SCRIPT_PATH})${NC}"
    echo ""
    echo -e "  ${BOLD}[4] Script 3 — restrict access (VM2 only, exclude VM3):${NC}"
    echo -e "      ${CYAN}sudo ./set-accesslist.sh${NC}"
    echo ""
}

# =============================================================================
# CMD: LIST — Show all entries in private addressbook
# =============================================================================
cmd_list() {
    check_i2p
    log_step "Private Addressbook Entries"
    local page
    page=$(curl -sf --max-time 10 \
        "${SUSIDNS_URL}/addressbook?book=private&filter=none" \
        2>/dev/null || echo "")

    if [[ -z "$page" ]]; then
        log_error "Could not fetch addressbook page."
        exit 1
    fi

    # Extract entries — they appear as hostname=destination in the page
    # Also show count
    echo ""
    echo -e "${BOLD}Private Addressbook — ${SUSIDNS_URL}/addressbook?book=private${NC}"
    echo ""

    # Parse the hosts from the page (they appear in table rows)
    local count=0
    while IFS= read -r line; do
        local host
        host=$(echo "$line" | grep -oE '[a-zA-Z0-9._-]+\.i2p' | head -1 || true)
        [[ -z "$host" ]] && continue
        echo -e "  ${CYAN}${host}${NC}"
        (( count++ )) || true
    done <<< "$(echo "$page" | grep -i '\.i2p')"

    if [[ $count -eq 0 ]]; then
        log_info "No entries found. Add with: sudo $0 add <domain>"
    else
        echo ""
        echo -e "  Total: ${BOLD}${count}${NC} entries"
    fi
    echo ""
}

# =============================================================================
# CMD: SHOW
# =============================================================================
cmd_show() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && { log_error "Usage: $0 show <domain>"; exit 1; }
    check_i2p

    local page
    page=$(curl -sf --max-time 10 \
        "${SUSIDNS_URL}/addressbook?book=private&filter=none" \
        2>/dev/null || echo "")

    if echo "$page" | grep -q "$domain"; then
        log_ok "'${domain}' found in private addressbook"
        echo ""
        echo -e "  View full entry: ${CYAN}${SUSIDNS_URL}/addressbook?book=private&filter=none${NC}"
        echo ""
    else
        log_error "'${domain}' not found in private addressbook."
        log_info  "Use: sudo $0 list"
    fi
}

# =============================================================================
# CMD: REMOVE
# =============================================================================
cmd_remove() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && { log_error "Usage: $0 remove <domain>"; exit 1; }
    check_i2p
    log_step "Removing Domain"
    remove_via_susidns "$domain"
    log_ok "Remove command sent for '${domain}'"
}

# =============================================================================
# USAGE
# =============================================================================
show_usage() {
    echo ""
    echo -e "${BOLD}customtld-manager.sh — Script 2 of 4${NC}"
    echo    "Invisible Within Invisible — IEEE MILCOM 2026"
    echo    "MIRAGe-UC — University of Cincinnati"
    echo ""
    echo -e "${BOLD}USAGE:${NC}"
    echo    "  sudo $0                      <- interactive (prompts for domain)"
    echo    "  sudo $0 add <domain>         <- add, auto-reads eepPriv.dat"
    echo    "  sudo $0 add <domain> <dest>  <- add with explicit destination (VM2)"
    echo    "  sudo $0 list                 <- list private addressbook"
    echo    "  sudo $0 show <domain>"
    echo    "  sudo $0 remove <domain>"
    echo ""
    echo -e "${BOLD}NOTE:${NC} Use .i2p extension. Custom TLDs (.mil .darkest)"
    echo    "      are NOT routed through I2P proxy by default."
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║     I2P Custom TLD Manager — Script 2 of 4                         ║${NC}"
    echo -e "${BOLD}${MAGENTA}║     Invisible Within Invisible — IEEE MILCOM 2026                  ║${NC}"
    echo -e "${BOLD}${MAGENTA}║     MIRAGe-UC — University of Cincinnati                           ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log_step "Auto-Detecting I2P Environment"
    detect_i2p

    local cmd="${1:-add}"
    shift || true

    case "$cmd" in
        add)    cmd_add    "$@" ;;
        list)   cmd_list        ;;
        show)   cmd_show   "$@" ;;
        remove) cmd_remove "$@" ;;
        help|--help|-h) show_usage ;;
        *)
            [[ "$cmd" =~ \. ]] && { cmd_add "$cmd" "$@"; return; }
            log_error "Unknown command: $cmd"
            show_usage; exit 1
            ;;
    esac
}

main "$@"
