#!/bin/bash
# =============================================================================
#  Script   : setup-scanner.sh
#  Version  : 1.0
#
#  Purpose  : One-time setup script for the Fifty Shades of the Darknet
#             I2P Network Scanner. Runs on any fresh VM that has only I2P
#             installed. Detects the OS, installs all required system and
#             Python packages, validates the I2P installation, creates output
#             directories, and runs a self-test to confirm the scanner is
#             ready to use.
#
#             Supports: Ubuntu/Debian, Fedora/RHEL/CentOS, Arch Linux.
#             Tested on: Ubuntu 26.04 LTS (Resolute Raccoon).
#
#  Author   : Siddique Abubakr Muntaka, PhD Candidate
#             Information Technology | University of Cincinnati, Ohio, USA
#  Advisor  : Dr. Jacques Bou Abdo
#             Multi-domain and Information Operations, Resilience and
#             Anonymity Group (MIRAGe-UC)
#
#  Usage    : sudo bash setup-scanner.sh
#             bash setup-scanner.sh          (will escalate where needed)
# =============================================================================

set -euo pipefail

# ── Identity ──────────────────────────────────────────────────────────────────
SCRIPT_NAME="setup-scanner.sh"
SCRIPT_VERSION="2.0"
SCANNER_NAME="fifty-shades-scanner.py"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# ── Colour codes ──────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';    DIM='\033[2m';    RESET='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_ok()    { echo -e "  ${GREEN}[✓]${RESET}  $*"; }
log_fail()  { echo -e "  ${RED}[✗]${RESET}  $*"; }
log_warn()  { echo -e "  ${YELLOW}[!]${RESET}  $*"; }
log_info()  { echo -e "  ${CYAN}[-]${RESET}  $*"; }
log_step()  { echo -e "\n  ${BOLD}${CYAN}━━ $* ━━${RESET}"; }
log_die()   { echo -e "\n  ${RED}${BOLD}[FATAL]${RESET} $*\n"; exit 1; }

# ── Track overall result ──────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check_pass() { PASS_COUNT=$((PASS_COUNT+1)); log_ok "$*"; }
check_fail() { FAIL_COUNT=$((FAIL_COUNT+1)); log_fail "$*"; }
check_warn() { WARN_COUNT=$((WARN_COUNT+1)); log_warn "$*"; }

# =============================================================================
#  BANNER
# =============================================================================
print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║   FIFTY SHADES OF THE DARKNET — Scanner Environment Setup        ║${RESET}"
    echo -e "${CYAN}${BOLD}║   Version ${SCRIPT_VERSION} | MIRAGe-UC | University of Cincinnati           ║${RESET}"
    echo -e "${CYAN}${BOLD}║   Author: Siddique Abubakr Muntaka | Advisor: Dr. Jacques Bou Abdo║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# =============================================================================
#  OS DETECTION
# =============================================================================
detect_os() {
    log_step "Detecting Operating System"

    OS_FAMILY=""
    OS_NAME=""
    OS_VERSION=""
    PKG_MANAGER=""
    PKG_UPDATE=""
    PKG_INSTALL=""

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="${NAME:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    fi

    if command -v apt-get &>/dev/null; then
        OS_FAMILY="debian"
        PKG_MANAGER="apt-get"
        PKG_UPDATE="apt-get update -qq"
        PKG_INSTALL="apt-get install -y -qq"
        check_pass "OS: ${OS_NAME} ${OS_VERSION} (Debian/Ubuntu family)"

    elif command -v dnf &>/dev/null; then
        OS_FAMILY="fedora"
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf makecache -q"
        PKG_INSTALL="dnf install -y -q"
        check_pass "OS: ${OS_NAME} ${OS_VERSION} (Fedora/RHEL family)"

    elif command -v yum &>/dev/null; then
        OS_FAMILY="rhel"
        PKG_MANAGER="yum"
        PKG_UPDATE="yum makecache -q"
        PKG_INSTALL="yum install -y -q"
        check_pass "OS: ${OS_NAME} ${OS_VERSION} (RHEL/CentOS family)"

    elif command -v pacman &>/dev/null; then
        OS_FAMILY="arch"
        PKG_MANAGER="pacman"
        PKG_UPDATE="pacman -Sy --noconfirm"
        PKG_INSTALL="pacman -S --noconfirm"
        check_pass "OS: ${OS_NAME} ${OS_VERSION} (Arch Linux family)"

    else
        log_die "Unsupported OS — cannot determine package manager."
    fi

    export OS_FAMILY OS_NAME OS_VERSION PKG_MANAGER PKG_UPDATE PKG_INSTALL
}

# =============================================================================
#  PRIVILEGE HANDLING
# =============================================================================
setup_privilege() {
    log_step "Checking Execution Privileges"

    SUDO_CMD=""

    if [[ $EUID -eq 0 ]]; then
        check_pass "Running as root — full privileges available"
        SUDO_CMD=""
    elif command -v sudo &>/dev/null; then
        if sudo -n true 2>/dev/null; then
            check_pass "sudo available and passwordless"
            SUDO_CMD="sudo"
        else
            log_info "sudo requires password. You may be prompted."
            SUDO_CMD="sudo"
            check_pass "sudo available"
        fi
    else
        log_die "Neither root nor sudo available. Cannot install packages."
    fi

    export SUDO_CMD
}

# =============================================================================
#  SYSTEM PACKAGE INSTALLATION
# =============================================================================
install_system_packages() {
    log_step "Installing System Packages"

    # ── Package name maps per OS family ──────────────────────────────────────
    declare -A PKG_PYTHON3=(
        [debian]="python3"
        [fedora]="python3"
        [rhel]="python3"
        [arch]="python"
    )
    declare -A PKG_PIP3=(
        [debian]="python3-pip"
        [fedora]="python3-pip"
        [rhel]="python3-pip"
        [arch]="python-pip"
    )
    declare -A PKG_BINUTILS=(
        [debian]="binutils"
        [fedora]="binutils"
        [rhel]="binutils"
        [arch]="binutils"
    )
    declare -A PKG_NETCAT=(
        [debian]="netcat-openbsd"
        [fedora]="nmap-ncat"
        [rhel]="nmap-ncat"
        [arch]="openbsd-netcat"
    )
    declare -A PKG_CURL=(
        [debian]="curl"
        [fedora]="curl"
        [rhel]="curl"
        [arch]="curl"
    )
    declare -A PKG_JQ=(
        [debian]="jq"
        [fedora]="jq"
        [rhel]="jq"
        [arch]="jq"
    )

    # ── Function: install one package if missing ──────────────────────────────
    ensure_pkg() {
        local cmd="$1"         # command to test
        local pkg_var="$2"     # associative array name
        local label="$3"       # display name

        # Indirect lookup of package name for this OS family
        local pkg_name
        eval "pkg_name=\${${pkg_var}[${OS_FAMILY}]:-}"

        if [[ -z "${pkg_name}" ]]; then
            check_warn "${label}: no package mapping for OS family '${OS_FAMILY}'"
            return
        fi

        if command -v "${cmd}" &>/dev/null; then
            check_pass "${label}: already installed ($(command -v ${cmd}))"
        else
            log_info "${label}: not found — installing ${pkg_name}..."
            if ${SUDO_CMD} ${PKG_INSTALL} "${pkg_name}" 2>&1 | tail -2; then
                if command -v "${cmd}" &>/dev/null; then
                    check_pass "${label}: installed successfully"
                else
                    check_fail "${label}: installation failed"
                fi
            else
                check_fail "${label}: package install command failed"
            fi
        fi
    }

    # ── Update package index once ─────────────────────────────────────────────
    log_info "Refreshing package index..."
    ${SUDO_CMD} ${PKG_UPDATE} 2>/dev/null || true

    # ── Install each required package ─────────────────────────────────────────
    ensure_pkg "python3"  "PKG_PYTHON3"  "Python 3"
    ensure_pkg "pip3"     "PKG_PIP3"     "pip3"
    ensure_pkg "strings"  "PKG_BINUTILS" "binutils (strings)"
    ensure_pkg "nc"       "PKG_NETCAT"   "netcat"
    ensure_pkg "curl"     "PKG_CURL"     "curl"
    ensure_pkg "jq"       "PKG_JQ"       "jq (optional)"
}

# =============================================================================
#  PYTHON VERSION VALIDATION
# =============================================================================
check_python() {
    log_step "Validating Python Environment"

    if ! command -v python3 &>/dev/null; then
        check_fail "python3 not found even after install attempt"
        return
    fi

    PYTHON_VERSION=$(python3 --version 2>&1 | grep -oP '[0-9]+\.[0-9]+' | head -1)
    PYTHON_MAJOR=$(echo "${PYTHON_VERSION}" | cut -d. -f1)
    PYTHON_MINOR=$(echo "${PYTHON_VERSION}" | cut -d. -f2)

    check_pass "python3 version: ${PYTHON_VERSION}"

    if [[ "${PYTHON_MAJOR}" -lt 3 ]] || { [[ "${PYTHON_MAJOR}" -eq 3 ]] && [[ "${PYTHON_MINOR}" -lt 8 ]]; }; then
        check_fail "Python 3.8+ required. Found: ${PYTHON_VERSION}"
    else
        check_pass "Python version requirement met (3.8+)"
    fi

    # ── Verify required stdlib modules ────────────────────────────────────────
    log_info "Checking required Python stdlib modules..."
    local modules=("os" "sys" "re" "json" "csv" "time" "socket" "struct" "base64"
                   "hashlib" "argparse" "subprocess" "urllib.request" "urllib.parse"
                   "pathlib" "datetime" "collections")

    local missing_mods=()
    for mod in "${modules[@]}"; do
        if ! python3 -c "import ${mod}" 2>/dev/null; then
            missing_mods+=("${mod}")
        fi
    done

    if [[ ${#missing_mods[@]} -eq 0 ]]; then
        check_pass "All required stdlib modules present"
    else
        check_fail "Missing stdlib modules: ${missing_mods[*]}"
    fi

    export PYTHON_VERSION PYTHON_MAJOR PYTHON_MINOR
}

# =============================================================================
#  PYTHON PACKAGE INSTALLATION
# =============================================================================
install_python_packages() {
    log_step "Installing Python Packages"

    # ── Determine pip invocation ──────────────────────────────────────────────
    PIP_CMD=""
    if command -v pip3 &>/dev/null; then
        PIP_CMD="pip3"
    elif python3 -m pip --version &>/dev/null 2>&1; then
        PIP_CMD="python3 -m pip"
    else
        check_warn "pip not available — Python packages will use stdlib only"
        check_warn "Scanner will work but without optional 'requests' library"
        return
    fi

    check_pass "pip command: ${PIP_CMD}"

    # ── Detect if pip is 'externally managed' (Ubuntu 23.04+, 26.04) ─────────
    PIP_FLAGS=""
    if python3 -m pip install --dry-run pip 2>&1 | grep -q "externally-managed"; then
        PIP_FLAGS="--break-system-packages"
        log_info "Ubuntu externally-managed environment detected — using ${PIP_FLAGS}"
    fi

    # ── Install packages ──────────────────────────────────────────────────────
    install_py_pkg() {
        local pkg="$1"
        local import_name="${2:-$1}"
        local required="${3:-optional}"

        if python3 -c "import ${import_name}" 2>/dev/null; then
            check_pass "Python package '${pkg}': already installed"
        else
            log_info "Installing Python package: ${pkg}..."
            if ${SUDO_CMD} ${PIP_CMD} install ${PIP_FLAGS} "${pkg}" -q 2>&1 | tail -1; then
                if python3 -c "import ${import_name}" 2>/dev/null; then
                    check_pass "Python package '${pkg}': installed"
                else
                    if [[ "${required}" == "required" ]]; then
                        check_fail "Python package '${pkg}': install failed (required)"
                    else
                        check_warn "Python package '${pkg}': install failed (optional — scanner will still work)"
                    fi
                fi
            else
                check_warn "Python package '${pkg}': pip install error (optional)"
            fi
        fi
    }

    install_py_pkg "requests" "requests" "optional"

    export PIP_CMD PIP_FLAGS
}

# =============================================================================
#  I2P INSTALLATION VALIDATION
# =============================================================================
validate_i2p() {
    log_step "Validating I2P Installation"

    # ── Check I2P process ─────────────────────────────────────────────────────
    I2P_PID=$(pgrep -f "net.i2p.router.Router" 2>/dev/null | head -1 || true)
    if [[ -n "${I2P_PID}" ]]; then
        I2P_USER=$(ps -o user= -p "${I2P_PID}" 2>/dev/null | tr -d ' ' || echo "unknown")
        check_pass "I2P process running (PID: ${I2P_PID}, user: ${I2P_USER})"
    else
        check_warn "I2P process not detected — start I2P before running the scanner"
    fi

    # ── Find router.config ────────────────────────────────────────────────────
    I2P_CONFIG_PATH=""
    NETDB_PATH=""

    search_paths=()
    # From process
    if [[ -n "${I2P_PID:-}" ]]; then
        I2P_USER_HOME=$(getent passwd "${I2P_USER}" 2>/dev/null | cut -d: -f6 || true)
        [[ -n "${I2P_USER_HOME}" ]] && search_paths+=("${I2P_USER_HOME}/.i2p")
    fi
    # Standard paths
    while IFS=: read -r uname _ uid _ _ uhome _; do
        [[ "${uid}" -ge 1000 ]] && search_paths+=("${uhome}/.i2p")
    done < /etc/passwd
    search_paths+=("/var/lib/i2p/i2p-config" "/root/.i2p" "${HOME}/.i2p")

    for path in "${search_paths[@]}"; do
        if [[ -f "${path}/router.config" ]]; then
            I2P_CONFIG_PATH="${path}"
            NETDB_PATH="${path}/netDb"
            break
        fi
    done

    if [[ -n "${I2P_CONFIG_PATH}" ]]; then
        check_pass "I2P config dir  : ${I2P_CONFIG_PATH}"
    else
        check_fail "I2P router.config not found. Is I2P installed and run at least once?"
    fi

    if [[ -n "${NETDB_PATH}" ]] && [[ -d "${NETDB_PATH}" ]]; then
        DAT_COUNT=$(find "${NETDB_PATH}" -name "*.dat" 2>/dev/null | wc -l)
        check_pass "NetDB directory : ${NETDB_PATH} (${DAT_COUNT} .dat files)"
    else
        check_warn "NetDB directory not found or empty — run I2P first to populate it"
    fi

    # ── Check I2P console ─────────────────────────────────────────────────────
    if curl -s --connect-timeout 3 "http://127.0.0.1:7657/" &>/dev/null; then
        check_pass "I2P console     : reachable at http://127.0.0.1:7657/"
    else
        check_warn "I2P console not reachable — start I2P before scanning"
    fi

    # ── Check and ENABLE SAM bridge ───────────────────────────────────────────
    SAM_ALIVE=false
    SAM_CONFIG_FILE=""

    # Find the SAM config file
    if [[ -n "${I2P_CONFIG_PATH}" ]]; then
        SAM_CONFIG_FILE="${I2P_CONFIG_PATH}/clients.config.d/01-net.i2p.sam.SAMBridge-clients.config"
    fi

    sam_check() {
        echo "HELLO VERSION MIN=3.0 MAX=3.3" | nc -w 3 127.0.0.1 7656 2>/dev/null | grep -q "RESULT=OK"
    }

    if sam_check; then
        check_pass "SAM bridge      : already running on port 7656"
        SAM_ALIVE=true
    else
        log_info "SAM bridge not running — attempting to enable now..."

        # Method 1: Edit config file to set startOnLoad=true (persists across restarts)
        if [[ -f "${SAM_CONFIG_FILE}" ]]; then
            if grep -q "startOnLoad=false" "${SAM_CONFIG_FILE}"; then
                sed -i 's/clientApp\.0\.startOnLoad=false/clientApp.0.startOnLoad=true/' \
                    "${SAM_CONFIG_FILE}" 2>/dev/null && \
                    log_info "SAM config updated: startOnLoad=true (persists after restart)"
            fi
        fi

        # Method 2: Start SAM immediately via console POST (no restart needed)
        # The configclients page lists SAM as client index 1.
        # POST action="Start 1" with a nonce to start it right now.
        if curl -s --connect-timeout 3 "http://127.0.0.1:7657/" &>/dev/null; then
            # Get the nonce from the configclients page
            NONCE=$(curl -s "http://127.0.0.1:7657/configclients" 2>/dev/null | \
                grep -oP '(?<=name="nonce" value=")[^"]+' | head -1)
            if [[ -n "${NONCE}" ]]; then
                log_info "Sending start command to SAM bridge (nonce: ${NONCE:0:8}...)..."
                curl -s -X POST "http://127.0.0.1:7657/configclients" \
                    --data "nonce=${NONCE}&action=Start+1" \
                    --header "Content-Type: application/x-www-form-urlencoded" \
                    -o /dev/null 2>/dev/null || true
            else
                log_info "Could not extract nonce — trying without nonce..."
                curl -s -X POST "http://127.0.0.1:7657/configclients" \
                    --data "action=Start+1" \
                    --header "Content-Type: application/x-www-form-urlencoded" \
                    -o /dev/null 2>/dev/null || true
            fi

            # Wait up to 30 seconds for SAM to come online
            log_info "Waiting for SAM bridge to start (up to 30 seconds)..."
            local waited=0
            while [[ $waited -lt 30 ]]; do
                sleep 2
                waited=$((waited + 2))
                if sam_check; then
                    check_pass "SAM bridge      : started successfully on port 7656 (after ${waited}s)"
                    SAM_ALIVE=true
                    break
                fi
                printf "  ${DIM}  Waiting... ${waited}s${RESET}\r"
            done

            if [[ "${SAM_ALIVE}" == "false" ]]; then
                check_warn "SAM bridge      : could not auto-start after 30s"
                log_info "Enable manually: I2P Console → Settings → Clients → SAM → ▶ Start"
                log_info "Or restart I2P: the config file was updated to start SAM automatically"
            fi
        else
            check_warn "SAM bridge      : I2P console not reachable — cannot auto-start"
        fi
    fi

    # ── strings tool test ─────────────────────────────────────────────────────
    if [[ -n "${NETDB_PATH}" ]] && [[ -d "${NETDB_PATH}" ]]; then
        SAMPLE_DAT=$(find "${NETDB_PATH}" -name "*.dat" 2>/dev/null | head -1)
        if [[ -n "${SAMPLE_DAT}" ]]; then
            LINE_COUNT=$(strings "${SAMPLE_DAT}" 2>/dev/null | wc -l)
            if [[ "${LINE_COUNT}" -gt 0 ]]; then
                check_pass "strings binary test: OK (${LINE_COUNT} lines from sample .dat)"
            else
                check_fail "strings returned 0 lines from .dat file — binutils broken?"
            fi
        fi
    fi

    export I2P_CONFIG_PATH NETDB_PATH SAM_ALIVE
}

# =============================================================================
#  SETUP OUTPUT DIRECTORIES
# =============================================================================
setup_directories() {
    log_step "Creating Output Directories"

    local dirs=(
        "./scanner-output"
        "./scanner-output/reports"
        "./scanner-output/json"
        "./scanner-output/csv"
        "./scanner-output/logs"
    )

    for d in "${dirs[@]}"; do
        if mkdir -p "${d}" 2>/dev/null; then
            check_pass "Created: ${d}"
        else
            check_warn "Could not create: ${d} — check permissions"
        fi
    done
}

# =============================================================================
#  SCANNER SELF-TEST
# =============================================================================
run_self_test() {
    log_step "Running Script Self-Tests"

    # Test each script that should be present
    local scripts=("node-lookup.py" "b32-lookup.py" "fifty-shades-scanner.py")
    local found_any=false

    for script in "${scripts[@]}"; do
        if [[ ! -f "${script}" ]]; then
            check_warn "Script '${script}' not found in current directory"
        else
            found_any=true
            if python3 -m py_compile "${script}" 2>/dev/null; then
                check_pass "${script}: syntax OK"
            else
                check_fail "${script}: syntax FAILED"
            fi
        fi
    done

    if [[ "${found_any}" == "false" ]]; then
        check_warn "No scripts found in current directory"
        check_warn "Place node-lookup.py, b32-lookup.py, fifty-shades-scanner.py here"
        return
    fi

    # Only run preflight on fifty-shades-scanner.py (it has --preflight flag)
    if [[ -f "fifty-shades-scanner.py" ]]; then
        if python3 "fifty-shades-scanner.py" --preflight 2>/dev/null; then
            check_pass "fifty-shades-scanner.py preflight: PASSED"
        else
            check_warn "fifty-shades-scanner.py preflight: reported issues (see above)"
        fi
    fi
}

# =============================================================================
#  WRITE ENVIRONMENT FILE
# =============================================================================
write_env_file() {
    log_step "Writing Environment Configuration"

    local env_file=".scanner-env"
    cat > "${env_file}" << EOF
# Auto-generated by ${SCRIPT_NAME} on $(date)
# Source this file before running the scanner:  source .scanner-env
SCANNER_I2P_CONFIG_DIR="${I2P_CONFIG_PATH:-}"
SCANNER_NETDB_PATH="${NETDB_PATH:-}"
SCANNER_OUTPUT_DIR="./scanner-output"
SCANNER_CONSOLE_URL="http://127.0.0.1:7657"
SCANNER_SAM_PORT="7656"
EOF
    check_pass "Environment file written: ${env_file}"
    log_info "To use: source .scanner-env before running the scanner"
}

# =============================================================================
#  FINAL SUMMARY
# =============================================================================
print_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}  ══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  SETUP SUMMARY${RESET}"
    echo -e "${CYAN}${BOLD}  ══════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${GREEN}[✓] Passed :${RESET} ${PASS_COUNT}"
    echo -e "  ${YELLOW}[!] Warnings:${RESET} ${WARN_COUNT}"
    echo -e "  ${RED}[✗] Failed :${RESET} ${FAIL_COUNT}"
    echo ""

    if [[ ${FAIL_COUNT} -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}  ✅  ENVIRONMENT READY — Scanner can be used now${RESET}"
        echo ""
        echo -e "  ${BOLD}Usage examples:${RESET}"
        echo    "    python3 node-lookup.py              ← Router node lookup (interactive)"
        echo    "    python3 b32-lookup.py               ← Eepsite/b32 lookup (interactive)"
        echo    "    python3 fifty-shades-scanner.py --scan-local"
        echo    "    python3 fifty-shades-scanner.py --lookup-node <hash_or_prefix>"
        echo    "    python3 fifty-shades-scanner.py --lookup-b32 stats.i2p"
        echo    "    python3 fifty-shades-scanner.py --probe-network --save"
        echo    "    python3 fifty-shades-scanner.py --report --save"
    elif [[ ${FAIL_COUNT} -le 2 ]]; then
        echo -e "  ${YELLOW}${BOLD}  ⚠  PARTIAL — Scanner may work with limitations${RESET}"
        echo    "  Review the failures above and resolve them before scanning."
    else
        echo -e "  ${RED}${BOLD}  ✗  NOT READY — Critical setup failures detected${RESET}"
        echo    "  Resolve all failures above before running the scanner."
    fi

    echo ""
    echo -e "  ${DIM}Setup log: ./scanner-output/logs/setup-${TIMESTAMP}.log${RESET}"
    echo ""
}

# =============================================================================
#  ENTRY POINT
# =============================================================================
{
    print_banner
    detect_os
    setup_privilege
    install_system_packages
    check_python
    install_python_packages
    validate_i2p
    setup_directories
    run_self_test
    write_env_file
    print_summary
} 2>&1 | tee -a "./scanner-setup-${TIMESTAMP}.log" || true

# Move log to output dir if it was created
mkdir -p ./scanner-output/logs 2>/dev/null || true
mv "./scanner-setup-${TIMESTAMP}.log" "./scanner-output/logs/" 2>/dev/null || true
