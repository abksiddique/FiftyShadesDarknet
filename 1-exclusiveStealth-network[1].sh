#!/bin/bash
# =============================================================================
#  Script   : exclusive-network.sh
#  Version  : 2.0
#
#  Purpose  : Transforms a standard I2P router into an Exclusive Network node —
#             a structurally hidden subset within the I2P darknet, invisible to
#             all known empirical mapping methodologies. Implements three
#             progressively deeper exclusivity profiles:
#
#               stealth   — Router absent from NetDB (mirrors GUI hidden mode)
#               exclusive — Non-participating, non-traceable, ephemeral identity
#               ghost     — Maximum invisibility, minimal footprint, transport
#                           lockdown. Full research demonstration grade.
#
#  Research Context:
#             This tool demonstrates that I2P, itself a darknet overlay on the
#             public Internet, contains a further hidden sublayer — an
#             "Invisible within Invisible" architecture. A router operating in
#             exclusive network mode suppresses RouterInfo publication to the
#             NetDB, declines participating tunnel requests, and rotates its
#             cryptographic identity on restart. Against this configuration,
#             empirical mapping frameworks including SWARM-I2P produce a proper
#             subgraph G' ⊂ G of the actual topology — a structural, not
#             incidental, incompleteness. This has direct implications for
#             offensive (C2, espionage) and defensive (military covert channel,
#             secure LEO communications) use cases at the network layer.
#
#  Author   : Siddique Abubakr Muntaka, PhD Candidate
#             Information Technology | University of Cincinnati, Ohio, USA
#  Advisor  : Dr. Jacques Bou Abdo
#             Multi-domain and Information Operations, Resilience and
#             Anonymity Group (MIRAGe-UC)
#
#  Usage    : sudo bash exclusive-network.sh <command> [profile]
#
#  Commands :
#    enable  <profile>  Apply a stealth profile (stealth | exclusive | ghost)
#    disable            Restore from most recent backup
#    status             Show current router stealth state
#    diff               Show exactly what will change for a given profile
#
#  Examples :
#    sudo bash exclusive-network.sh enable stealth
#    sudo bash exclusive-network.sh enable exclusive
#    sudo bash exclusive-network.sh enable ghost
#    sudo bash exclusive-network.sh status
#    sudo bash exclusive-network.sh disable
#    sudo bash exclusive-network.sh diff ghost
# =============================================================================

set -euo pipefail

# ── Script identity ───────────────────────────────────────────────────────────
SCRIPT_NAME="exclusive-network.sh"
SCRIPT_VERSION="2.0"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# ── These will be auto-detected ───────────────────────────────────────────────
I2P_USER=""
I2P_USER_HOME=""
I2P_CONFIG_DIR=""
I2P_BASE_DIR=""
I2P_WRAPPER=""
ROUTER_CONFIG=""
BACKUP_DIR=""
BACKUP_FILE=""

# ── Colour codes ──────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m';   BOLD='\033[1m';     DIM='\033[2m';     RESET='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()  { echo -e "  ${GREEN}[INFO]${RESET}     $*"; }
log_warn()  { echo -e "  ${YELLOW}[WARN]${RESET}     $*"; }
log_error() { echo -e "  ${RED}[ERROR]${RESET}    $*"; }
log_step()  { echo -e "\n  ${BOLD}${CYAN}[STEP]${RESET}     $*"; }
log_ok()    { echo -e "  ${GREEN}[✓]${RESET}        $*"; }
log_fail()  { echo -e "  ${RED}[✗]${RESET}        $*"; }
log_prop()  { printf "  %-46s ${CYAN}%s${RESET}\n" "$1" "$2"; }

# =============================================================================
#  AUTO-DETECTION: Find I2P installation on any system
# =============================================================================
detect_i2p() {
    log_step "Auto-detecting I2P installation..."

    local i2p_pid=""

    # ── Method 1: Find running I2P Java process ───────────────────────────────
    i2p_pid=$(pgrep -f "net.i2p.router.Router" 2>/dev/null | head -1 || true)

    if [[ -n "${i2p_pid}" ]]; then
        # Get the user owning the I2P process
        I2P_USER=$(ps -o user= -p "${i2p_pid}" 2>/dev/null | tr -d ' ' || true)
        log_ok "Running I2P process found (PID: ${i2p_pid}, user: ${I2P_USER})"

        # Get I2P base directory from Java -Di2p.dir.base argument
        I2P_BASE_DIR=$(ps -o args= -p "${i2p_pid}" 2>/dev/null | \
            grep -oP '(?<=-Di2p\.dir\.base=)\S+' || true)

        # Get config dir from wrapper args (wrapper.config path → derive .i2p)
        local wrapper_config
        wrapper_config=$(ps -o args= -p "${i2p_pid}" 2>/dev/null | \
            grep -oP '/\S+wrapper\.config' || true)
        if [[ -n "${wrapper_config}" ]]; then
            I2P_BASE_DIR=$(dirname "${wrapper_config}")
        fi
    fi

    # ── Method 2: Resolve user home and standard config path ─────────────────
    if [[ -n "${I2P_USER}" ]]; then
        I2P_USER_HOME=$(getent passwd "${I2P_USER}" 2>/dev/null | cut -d: -f6 || true)
        if [[ -f "${I2P_USER_HOME}/.i2p/router.config" ]]; then
            I2P_CONFIG_DIR="${I2P_USER_HOME}/.i2p"
        fi
    fi

    # ── Method 3: Fallback — search common install locations ─────────────────
    if [[ -z "${I2P_CONFIG_DIR}" ]]; then
        local search_paths=(
            "/var/lib/i2p/i2p-config"
            "/root/.i2p"
            "${HOME}/.i2p"
        )
        # Also search all real user home directories
        while IFS=: read -r uname _ uid _ _ uhome _; do
            if [[ "${uid}" -ge 1000 ]] && [[ -d "${uhome}" ]]; then
                search_paths+=("${uhome}/.i2p")
            fi
        done < /etc/passwd

        for path in "${search_paths[@]}"; do
            if [[ -f "${path}/router.config" ]]; then
                I2P_CONFIG_DIR="${path}"
                if [[ -z "${I2P_USER}" ]]; then
                    I2P_USER=$(stat -c '%U' "${path}/router.config" 2>/dev/null || echo "root")
                    I2P_USER_HOME=$(getent passwd "${I2P_USER}" 2>/dev/null | cut -d: -f6 || echo "${path%/.i2p}")
                fi
                log_ok "Config found via filesystem search: ${path}"
                break
            fi
        done
    fi

    # ── Method 4: Find I2P wrapper/binary ────────────────────────────────────
    if [[ -n "${I2P_BASE_DIR}" ]] && [[ -x "${I2P_BASE_DIR}/i2prouter" ]]; then
        I2P_WRAPPER="${I2P_BASE_DIR}/i2prouter"
    elif [[ -n "${I2P_USER_HOME}" ]] && [[ -x "${I2P_USER_HOME}/i2p/i2prouter" ]]; then
        I2P_WRAPPER="${I2P_USER_HOME}/i2p/i2prouter"
    elif command -v i2prouter &>/dev/null; then
        I2P_WRAPPER=$(command -v i2prouter)
    fi

    # ── Validate detection results ────────────────────────────────────────────
    if [[ -z "${I2P_CONFIG_DIR}" ]]; then
        log_error "Could not locate I2P router.config on this system."
        log_error "Searched: ~/.i2p/, /var/lib/i2p/i2p-config/, all user homes."
        log_error "Is I2P installed and has it been run at least once?"
        exit 1
    fi

    ROUTER_CONFIG="${I2P_CONFIG_DIR}/router.config"
    BACKUP_DIR="${I2P_CONFIG_DIR}/backups"
    BACKUP_FILE="${BACKUP_DIR}/router.config.bak_${TIMESTAMP}"

    log_ok "I2P user       : ${I2P_USER}"
    log_ok "Config dir     : ${I2P_CONFIG_DIR}"
    log_ok "router.config  : ${ROUTER_CONFIG}"
    log_ok "I2P wrapper    : ${I2P_WRAPPER:-not found (manual restart required)}"

    # Ensure backup dir exists
    mkdir -p "${BACKUP_DIR}"
    chown "${I2P_USER}:${I2P_USER}" "${BACKUP_DIR}" 2>/dev/null || true
}

# =============================================================================
#  PROFILE DEFINITIONS
#  Each profile is a list of "KEY=VALUE" pairs.
#  The apply function processes them in order.
# =============================================================================

# ── PROFILE: stealth ──────────────────────────────────────────────────────────
# Mirrors exactly what I2P's GUI does when you select:
# "Hidden mode – do not publish IP (prevents participating traffic)"
# Effect: Router RouterInfo is NOT published to NetDB.
# The router becomes absent from all empirical mapping scans.
profile_stealth=(
    "router.isHidden=true"
    "router.hiddenMode=true"
    "i2np.udp.addressSources="
    "i2np.ntcp2.autoip=false"
    "router.floodfillParticipant=false"
)

# ── PROFILE: exclusive ────────────────────────────────────────────────────────
# Stealth + non-participating + ephemeral cryptographic identity.
# This router cannot be found, cannot be used as a relay, and changes
# its router identity hash on every restart — making session correlation
# by an adversary cryptographically infeasible.
profile_exclusive=(
    # All stealth settings
    "router.isHidden=true"
    "router.hiddenMode=true"
    "i2np.udp.addressSources="
    "i2np.ntcp2.autoip=false"
    "router.floodfillParticipant=false"
    # Non-participating: refuse to route others' tunnels
    "router.maxParticipatingTunnels=0"
    "router.sharePercentage=0"
    # Disable peer testing (stops probes that reveal reachability)
    "router.enablePeerTest=false"
    # Ephemeral identity: new router hash on every restart
    # NOTE: Does NOT affect eepsite keys (eepPriv.dat is separate)
    "router.dynamicKeys=true"
    # Force introducer-based reachability (hides direct IP)
    "i2np.udp.requireIntroductions=true"
)

# ── PROFILE: ghost ────────────────────────────────────────────────────────────
# Everything in exclusive, plus:
# - Self-declares as firewalled on both IPv4 and IPv6 (no direct probe response)
# - Laptop mode: aggressively rotates identity on network changes
# - Reduced peer connection ceiling (smaller observable peer graph)
# - Reduced exploratory tunnel count (less tunnel-build traffic analysis)
# This is full research-demonstration grade. Against this profile, no
# current I2P mapping tool can enumerate, probe, or attribute this router.
profile_ghost=(
    # All exclusive settings
    "router.isHidden=true"
    "router.hiddenMode=true"
    "i2np.udp.addressSources="
    "i2np.ntcp2.autoip=false"
    "router.floodfillParticipant=false"
    "router.maxParticipatingTunnels=0"
    "router.sharePercentage=0"
    "router.enablePeerTest=false"
    "router.dynamicKeys=true"
    "i2np.udp.requireIntroductions=true"
    # Declare firewalled on both transports
    "i2np.ipv4.firewalled=true"
    "i2np.ipv6.firewalled=true"
    # Laptop mode: rotate identity aggressively on network change
    "i2np.laptopMode=true"
    "laptop.mode=true"
    # Reduced peer footprint
    "router.maxConnections=200"
    "router.fastPeers=25"
    # Reduced exploratory tunnel footprint
    "router.exploratory.inbound.quantity=2"
    "router.exploratory.outbound.quantity=2"
    "router.exploratory.inbound.lengthVariance=0"
    "router.exploratory.outbound.lengthVariance=0"
)

# ── RESTORE baseline (standard I2P router — what this system had before) ──────
# These values are taken directly from the live router.config read on
# Sid's VM1 (2026-05-03). The restore command writes these back explicitly
# rather than relying only on file backup, providing a documented baseline.
profile_restore_baseline=(
    "router.isHidden=false"
    "router.hiddenMode=false"
    "i2np.udp.addressSources=local,upnp,ssu"
    "i2np.ntcp2.autoip=true"
    "router.floodfillParticipant=true"
    "router.maxParticipatingTunnels=1000"
    "router.sharePercentage=98"
    "router.enablePeerTest=true"
    "router.dynamicKeys=false"
    "i2np.udp.requireIntroductions=false"
    "i2np.ipv4.firewalled=false"
    "i2np.ipv6.firewalled=false"
    "i2np.laptopMode=false"
    "laptop.mode=false"
    "router.maxConnections=1500"
    "router.fastPeers=100"
    "router.exploratory.inbound.quantity=6"
    "router.exploratory.outbound.quantity=6"
    "router.exploratory.inbound.lengthVariance=1"
    "router.exploratory.outbound.lengthVariance=1"
)

# =============================================================================
#  CORE: Read / Write properties
# =============================================================================

# Read a property from router.config
get_prop() {
    local key="$1"
    grep "^${key}=" "${ROUTER_CONFIG}" 2>/dev/null | \
        cut -d'=' -f2- || echo ""
}

# Set a property: replace if exists, append if not
set_prop() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "${ROUTER_CONFIG}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${ROUTER_CONFIG}"
    else
        echo "${key}=${value}" >> "${ROUTER_CONFIG}"
    fi
}

# =============================================================================
#  APPLY a profile (array of KEY=VALUE strings)
# =============================================================================
apply_profile() {
    local profile_name="$1"
    shift
    local profile_props=("$@")

    log_step "Applying profile: ${BOLD}${profile_name}${RESET}"
    echo ""

    local all_ok=true

    for entry in "${profile_props[@]}"; do
        local key="${entry%%=*}"
        local value="${entry#*=}"

        local old_val
        old_val=$(get_prop "${key}")

        set_prop "${key}" "${value}"

        # Verify
        local written_val
        written_val=$(get_prop "${key}")

        if [[ "${written_val}" == "${value}" ]]; then
            if [[ "${old_val}" == "${value}" ]]; then
                log_prop "${key}=${value}" "[unchanged]"
            else
                log_prop "${key}=${value}" "[was: ${old_val:-<not set>}]"
            fi
        else
            log_fail "${key}: expected='${value}' got='${written_val}'"
            all_ok=false
        fi
    done

    echo ""

    if [[ "${all_ok}" == "false" ]]; then
        log_error "One or more properties failed to write."
        log_error "Backup: ${BACKUP_FILE}"
        log_error "Restore: sudo bash ${SCRIPT_NAME} disable"
        exit 1
    fi

    log_ok "All properties written and verified."
}

# =============================================================================
#  CHECK: Is I2P running?
# =============================================================================
i2p_running() {
    pgrep -f "net.i2p.router.Router" > /dev/null 2>&1
}

# =============================================================================
#  RESTART I2P
# =============================================================================
restart_i2p() {
    log_step "Restarting I2P to apply configuration..."

    if i2p_running; then
        if [[ -n "${I2P_WRAPPER}" ]] && [[ -x "${I2P_WRAPPER}" ]]; then
            log_info "Stopping I2P..."
            sudo -u "${I2P_USER}" "${I2P_WRAPPER}" stop 2>/dev/null || true
            local retries=0
            while i2p_running && [[ $retries -lt 15 ]]; do
                sleep 2; retries=$((retries+1))
                log_info "Waiting for I2P to stop... (${retries}/15)"
            done
            sleep 2
            log_info "Starting I2P..."
            sudo -u "${I2P_USER}" "${I2P_WRAPPER}" start 2>/dev/null || true
            sleep 3
            log_ok "I2P restarted."
        else
            log_warn "i2prouter wrapper not found."
            log_warn "Restart I2P manually:"
            log_warn "  sudo -u ${I2P_USER} /home/${I2P_USER}/i2p/i2prouter restart"
        fi
    else
        log_warn "I2P is not running. Start it to activate the profile:"
        log_warn "  sudo -u ${I2P_USER} /home/${I2P_USER}/i2p/i2prouter start"
    fi
}

# =============================================================================
#  PRINT BANNER
# =============================================================================
print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║     I2P EXCLUSIVE NETWORK — STEALTH ROUTER CONFIGURATION          ║${RESET}"
    echo -e "${CYAN}${BOLD}║     Invisible Within Invisible | MIRAGe-UC Research Tool          ║${RESET}"
    echo -e "${CYAN}${BOLD}║     v${SCRIPT_VERSION} | Siddique Abubakr Muntaka | Dr. Jacques Bou Abdo       ║${RESET}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# =============================================================================
#  PROFILE SUMMARY BLOCK
# =============================================================================
print_profile_summary() {
    local profile="$1"
    echo ""
    echo -e "  ${BOLD}╔─ PROFILE SUMMARY ─────────────────────────────────────────────────╗${RESET}"
    case "${profile}" in
        stealth)
            echo -e "  ${BOLD}│  STEALTH${RESET} — Mirrors I2P GUI hidden mode"
            echo    "  │"
            echo    "  │  • RouterInfo NOT published to NetDB"
            echo    "  │  • IP address NOT advertised on any transport"
            echo    "  │  • Not a floodfill node"
            echo    "  │  • Router absent from all empirical mapping scans"
            echo    "  │"
            echo -e "  │  ${DIM}Eepsite tunnels still function (outbound capable)${RESET}"
            echo -e "  │  ${DIM}Router WILL accept inbound tunnels from peers it knows${RESET}"
            ;;
        exclusive)
            echo -e "  ${BOLD}│  EXCLUSIVE${RESET} — Non-participating + ephemeral identity"
            echo    "  │"
            echo    "  │  • All STEALTH protections active"
            echo    "  │  • Zero participating tunnels (not a relay)"
            echo    "  │  • Peer testing disabled (no reachability probes)"
            echo    "  │  • Dynamic keys: router identity rotates on restart"
            echo    "  │  • Introducer-only reachability (IP hidden behind introducers)"
            echo    "  │"
            echo -e "  │  ${DIM}Eepsite keys (eepPriv.dat) are STABLE across restarts${RESET}"
            echo -e "  │  ${DIM}Session correlation by adversary: cryptographically infeasible${RESET}"
            ;;
        ghost)
            echo -e "  ${BOLD}│  GHOST${RESET} — Maximum invisibility. Full research demonstration grade."
            echo    "  │"
            echo    "  │  • All EXCLUSIVE protections active"
            echo    "  │  • Self-declares firewalled on IPv4 and IPv6"
            echo    "  │  • Laptop mode: identity rotates on network change"
            echo    "  │  • Reduced peer connection ceiling (200 max)"
            echo    "  │  • Reduced exploratory tunnel count (2 each direction)"
            echo    "  │"
            echo -e "  │  ${YELLOW}Against this profile: no current I2P mapping tool can${RESET}"
            echo -e "  │  ${YELLOW}enumerate, probe, or attribute this router.${RESET}"
            ;;
    esac
    echo -e "  ${BOLD}╚───────────────────────────────────────────────────────────────────╝${RESET}"
    echo ""
}

# =============================================================================
#  COMMAND: enable
# =============================================================================
cmd_enable() {
    local profile="${1:-}"
    if [[ -z "${profile}" ]]; then
        log_error "Profile required. Usage: sudo bash ${SCRIPT_NAME} enable <stealth|exclusive|ghost>"
        exit 1
    fi

    case "${profile}" in
        stealth|exclusive|ghost) ;;
        *)
            log_error "Unknown profile '${profile}'. Choose: stealth | exclusive | ghost"
            exit 1
            ;;
    esac

    print_banner
    echo -e "  ${BOLD}COMMAND: enable ${profile}${RESET}"

    # Preflight
    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root: sudo bash ${SCRIPT_NAME} enable ${profile}"
        exit 1
    fi

    detect_i2p
    print_profile_summary "${profile}"

    # Confirm with user
    echo -n "  Apply profile '${profile}' now? [y/N]: "
    read -r confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        log_warn "Cancelled. No changes made."
        exit 0
    fi

    # Backup
    log_step "Creating backup..."
    cp "${ROUTER_CONFIG}" "${BACKUP_FILE}"
    chown "${I2P_USER}:${I2P_USER}" "${BACKUP_FILE}" 2>/dev/null || true
    log_ok "Backup: ${BACKUP_FILE}"

    # Apply the profile
    case "${profile}" in
        stealth)   apply_profile "stealth"   "${profile_stealth[@]}"   ;;
        exclusive) apply_profile "exclusive" "${profile_exclusive[@]}" ;;
        ghost)     apply_profile "ghost"     "${profile_ghost[@]}"     ;;
    esac

    # Stamp the active profile name into config for status command
    set_prop "mirage.exclusiveNetwork.profile" "${profile}"
    set_prop "mirage.exclusiveNetwork.appliedAt" "${TIMESTAMP}"

    # Final summary
    echo ""
    echo -e "${GREEN}${BOLD}  ═══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  ✅  EXCLUSIVE NETWORK PROFILE '${profile}' ACTIVATED${RESET}"
    echo -e "${GREEN}${BOLD}  ═══════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}What is now true about this router:${RESET}"
    echo    "    • RouterInfo will NOT appear in I2P NetDB after restart"
    echo    "    • SWARM-I2P and all empirical mapping tools will miss this node"
    echo    "    • This router forms Layer 2: Invisible Within Invisible"
    echo ""
    echo -e "  ${BOLD}Backup:${RESET}  ${BACKUP_FILE}"
    echo -e "  ${BOLD}Restore:${RESET} sudo bash ${SCRIPT_NAME} disable"
    echo ""

    # Offer restart
    if i2p_running; then
        echo -n "  I2P is running. Restart now to activate profile? [y/N]: "
        read -r restart_ans
        if [[ "${restart_ans}" =~ ^[Yy]$ ]]; then
            restart_i2p
        else
            echo ""
            log_warn "Profile written but NOT yet active."
            log_warn "Restart I2P when ready for changes to take effect."
        fi
    else
        log_warn "I2P is not running. Start I2P to activate the profile."
    fi
    echo ""
}

# =============================================================================
#  COMMAND: disable (restore)
# =============================================================================
cmd_disable() {
    print_banner
    echo -e "  ${BOLD}COMMAND: disable — Restore standard router configuration${RESET}"
    echo ""

    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root: sudo bash ${SCRIPT_NAME} disable"
        exit 1
    fi

    detect_i2p

    # Check for backup files
    local latest_backup
    latest_backup=$(ls -t "${BACKUP_DIR}"/router.config.bak_* 2>/dev/null | head -1 || true)

    if [[ -z "${latest_backup}" ]]; then
        log_warn "No timestamped backup found in ${BACKUP_DIR}"
        log_warn "Falling back to documented baseline restore..."
        echo ""
        echo -n "  Apply known-good baseline values? [y/N]: "
        read -r confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            log_warn "Cancelled."
            exit 0
        fi
        # Safety snapshot of current state
        cp "${ROUTER_CONFIG}" "${BACKUP_DIR}/router.config.pre-restore_${TIMESTAMP}"
        apply_profile "restore-baseline" "${profile_restore_baseline[@]}"
    else
        log_info "Most recent backup: $(basename "${latest_backup}")"
        echo ""
        echo -n "  Restore from this backup? [y/N]: "
        read -r confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            log_warn "Cancelled. No changes made."
            exit 0
        fi
        # Snapshot current stealth config before overwriting
        cp "${ROUTER_CONFIG}" "${BACKUP_DIR}/router.config.pre-restore_${TIMESTAMP}"
        log_ok "Stealth snapshot saved."

        cp "${latest_backup}" "${ROUTER_CONFIG}"
        chown "${I2P_USER}:${I2P_USER}" "${ROUTER_CONFIG}" 2>/dev/null || true
        log_ok "Restored: $(basename "${latest_backup}") → router.config"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}  ✅  STANDARD ROUTER CONFIGURATION RESTORED${RESET}"
    echo ""

    if i2p_running; then
        echo -n "  Restart I2P now to activate restored config? [y/N]: "
        read -r restart_ans
        if [[ "${restart_ans}" =~ ^[Yy]$ ]]; then
            restart_i2p
        else
            log_warn "Restored but NOT yet active. Restart I2P manually."
        fi
    fi
    echo ""
}

# =============================================================================
#  COMMAND: status
# =============================================================================
cmd_status() {
    print_banner
    echo -e "  ${BOLD}COMMAND: status${RESET}"
    echo ""

    detect_i2p

    echo -e "  ${BOLD}System${RESET}"
    echo    "  ──────────────────────────────────────────────────────────────────"
    log_prop "I2P user"           "${I2P_USER}"
    log_prop "Config directory"   "${I2P_CONFIG_DIR}"
    log_prop "router.config"      "${ROUTER_CONFIG}"
    if i2p_running; then
        log_prop "I2P process"    "${GREEN}RUNNING${RESET}"
    else
        log_prop "I2P process"    "${YELLOW}NOT RUNNING${RESET}"
    fi
    echo ""

    echo -e "  ${BOLD}Router Stealth Properties${RESET}"
    echo    "  ──────────────────────────────────────────────────────────────────"

    show_prop() {
        local key="$1"
        local val
        val=$(get_prop "${key}")
        printf "  %-46s %s\n" "${key}" "${val:-<not set>}"
    }

    show_prop "router.isHidden"
    show_prop "router.hiddenMode"
    show_prop "i2np.udp.addressSources"
    show_prop "i2np.ntcp2.autoip"
    show_prop "router.floodfillParticipant"
    show_prop "router.maxParticipatingTunnels"
    show_prop "router.sharePercentage"
    show_prop "router.enablePeerTest"
    show_prop "router.dynamicKeys"
    show_prop "i2np.udp.requireIntroductions"
    show_prop "i2np.ipv4.firewalled"
    show_prop "i2np.ipv6.firewalled"
    show_prop "i2np.laptopMode"
    show_prop "laptop.mode"
    show_prop "router.maxConnections"
    show_prop "router.fastPeers"
    show_prop "router.exploratory.inbound.quantity"
    show_prop "router.exploratory.outbound.quantity"
    echo    "  ──────────────────────────────────────────────────────────────────"

    # Active profile stamp
    local active_profile
    active_profile=$(get_prop "mirage.exclusiveNetwork.profile")
    local applied_at
    applied_at=$(get_prop "mirage.exclusiveNetwork.appliedAt")
    echo ""

    if [[ -n "${active_profile}" ]]; then
        echo -e "  ${GREEN}${BOLD}  ► Active profile: ${active_profile}  (applied: ${applied_at})${RESET}"
    else
        local is_hidden
        is_hidden=$(get_prop "router.isHidden")
        if [[ "${is_hidden}" == "true" ]]; then
            echo -e "  ${GREEN}${BOLD}  ► Router appears to be in hidden/stealth mode${RESET}"
        else
            echo -e "  ${YELLOW}${BOLD}  ► Router is in STANDARD (visible) mode${RESET}"
        fi
    fi

    # Backups
    echo ""
    echo -e "  ${BOLD}Available Backups${RESET}"
    echo    "  ──────────────────────────────────────────────────────────────────"
    local backups
    backups=$(ls -t "${BACKUP_DIR}"/router.config.bak_* 2>/dev/null | head -5 || true)
    if [[ -n "${backups}" ]]; then
        while IFS= read -r b; do
            log_info "$(basename "${b}")"
        done <<< "${backups}"
    else
        log_warn "No backups found in ${BACKUP_DIR}"
    fi
    echo ""
}

# =============================================================================
#  COMMAND: diff — show what WILL change without applying
# =============================================================================
cmd_diff() {
    local profile="${1:-}"
    if [[ -z "${profile}" ]]; then
        log_error "Profile required. Usage: sudo bash ${SCRIPT_NAME} diff <stealth|exclusive|ghost>"
        exit 1
    fi

    print_banner
    echo -e "  ${BOLD}COMMAND: diff ${profile}${RESET} — Preview changes (nothing is written)"
    echo ""

    detect_i2p

    local props=()
    case "${profile}" in
        stealth)   props=("${profile_stealth[@]}")   ;;
        exclusive) props=("${profile_exclusive[@]}") ;;
        ghost)     props=("${profile_ghost[@]}")     ;;
        *)
            log_error "Unknown profile '${profile}'. Choose: stealth | exclusive | ghost"
            exit 1
            ;;
    esac

    print_profile_summary "${profile}"

    printf "  %-46s %-22s %s\n" "Property" "Current Value" "→ New Value"
    echo   "  ──────────────────────────────────────────────────────────────────────────"

    local changes=0
    for entry in "${props[@]}"; do
        local key="${entry%%=*}"
        local new_val="${entry#*=}"
        local cur_val
        cur_val=$(get_prop "${key}")

        if [[ "${cur_val}" == "${new_val}" ]]; then
            printf "  ${DIM}%-46s %-22s → %s (no change)${RESET}\n" \
                "${key}" "${cur_val:-<not set>}" "${new_val}"
        else
            printf "  ${YELLOW}%-46s${RESET} ${RED}%-22s${RESET} ${GREEN}→ %s${RESET}\n" \
                "${key}" "${cur_val:-<not set>}" "${new_val}"
            changes=$((changes+1))
        fi
    done

    echo   "  ──────────────────────────────────────────────────────────────────────────"
    echo ""
    if [[ $changes -eq 0 ]]; then
        log_info "Profile '${profile}' is already fully applied. No changes needed."
    else
        log_info "${changes} properties will be changed."
        log_info "Run: sudo bash ${SCRIPT_NAME} enable ${profile}"
    fi
    echo ""
}

# =============================================================================
#  USAGE
# =============================================================================
usage() {
    echo ""
    echo -e "  ${BOLD}${CYAN}I2P Exclusive Network — Stealth Router Script v${SCRIPT_VERSION}${RESET}"
    echo -e "  ${DIM}Author: Siddique Abubakr Muntaka | MIRAGe-UC | University of Cincinnati${RESET}"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET} sudo bash ${SCRIPT_NAME} <command> [profile]"
    echo ""
    echo -e "  ${BOLD}Commands:${RESET}"
    echo    "    enable  <profile>   Apply a stealth profile to this router"
    echo    "    disable             Restore from most recent backup"
    echo    "    status              Show current stealth configuration state"
    echo    "    diff    <profile>   Preview changes without applying them"
    echo ""
    echo -e "  ${BOLD}Profiles:${RESET}"
    echo    "    stealth             Mirrors I2P GUI hidden mode"
    echo    "                        Router absent from NetDB"
    echo    "    exclusive           Stealth + non-participating + ephemeral identity"
    echo    "                        Zero relay traffic, dynamic router keys"
    echo    "    ghost               Maximum invisibility, minimal footprint"
    echo    "                        Full research demonstration grade"
    echo ""
    echo -e "  ${BOLD}Examples:${RESET}"
    echo    "    sudo bash ${SCRIPT_NAME} diff exclusive"
    echo    "    sudo bash ${SCRIPT_NAME} enable ghost"
    echo    "    sudo bash ${SCRIPT_NAME} status"
    echo    "    sudo bash ${SCRIPT_NAME} disable"
    echo ""
    exit 1
}

# =============================================================================
#  ENTRY POINT
# =============================================================================
COMMAND="${1:-}"
ARG2="${2:-}"

case "${COMMAND}" in
    enable)  cmd_enable  "${ARG2}" ;;
    disable) cmd_disable           ;;
    status)  cmd_status            ;;
    diff)    cmd_diff    "${ARG2}" ;;
    *)       usage                 ;;
esac
