#!/bin/bash

################################################################################
#                                                                              #
#  I2P Research Infrastructure - Script 13: Comprehensive UDP Fix             #
#                                                                              #
#  Design by: Siddique Abubakar Muntaka                                       #
#  University of Cincinnati, PhD Information Technology                       #
#  Advisor: Dr. Jacques Bou Abdo                                              #
#  Lab: Center of Anonymity Networks                                          #
#  School of Information Technology                                           #
#                                                                              #
#  Root cause analysis:                                                        #
#    1. Scripts 03-06 NEVER set i2np.udp.enable=true (omission)              #
#    2. Script 07 set fake key i2np.udp.inbound=true (invalid, ignored)      #
#    3. VirtualBox NAT blocks inbound UDP → I2P self-disables UDP transport  #
#                                                                              #
################################################################################

set -e

RESEARCH_USER="sid"
CONFIG_DIR="/home/$RESEARCH_USER/.i2p"
ROUTER_CONFIG="$CONFIG_DIR/router.config"
BACKUP_DIR="$CONFIG_DIR/backups"
I2P_PORT="24180"

echo "=============================================================================="
echo "  I2P Research Infrastructure - Script 13: Comprehensive UDP Fix"
echo "  Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root. Use: sudo bash $0"
    exit 1
fi

if [ ! -f "$ROUTER_CONFIG" ]; then
    echo "ERROR: router.config not found at $ROUTER_CONFIG"
    exit 1
fi

# ============================================================================
# STEP 1: Diagnostics
# ============================================================================
echo "[1/7] Pre-fix diagnostics..."
echo ""
echo "  --- All UDP/NTCP/transport lines currently in router.config ---"
grep -E "i2np\.(udp|ntcp|ssu)" "$ROUTER_CONFIG" 2>/dev/null | sed 's/^/  /' \
    || echo "  (none found)"
echo ""

echo "  --- Networking mode check ---"
# Detect if running in VirtualBox
if lspci 2>/dev/null | grep -qi virtualbox; then
    echo "  DETECTED: VirtualBox environment"
    VBOX=true
else
    echo "  Environment: Physical/other VM"
    VBOX=false
fi
echo ""

# ============================================================================
# STEP 2: Stop I2P and wait for full config flush
# ============================================================================
echo "[2/7] Stopping I2P (waiting for config flush)..."
if systemctl is-active --quiet i2p.service 2>/dev/null; then
    systemctl stop i2p.service
    echo "  Stopped. Waiting 8 seconds for I2P to finish writing config..."
    sleep 8
else
    echo "  I2P was already stopped."
fi

# ============================================================================
# STEP 3: Backup
# ============================================================================
echo "[3/7] Backing up router.config..."
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp "$ROUTER_CONFIG" "$BACKUP_DIR/router.config.pre_script13_$TIMESTAMP"
echo "  Backup: $BACKUP_DIR/router.config.pre_script13_$TIMESTAMP"

# ============================================================================
# STEP 4: Atomic config rewrite
# Remove ALL conflicting transport keys in one pass, then write a clean block.
# This handles duplicates, invalid keys from Script 07, and legacy keys.
# ============================================================================
echo "[4/7] Atomic config fix..."

# Strip every transport-related key that any prior script may have set
# (valid or invalid, duplicate or not)
sed -i \
    -e '/^i2np\.udp\.enable=/d' \
    -e '/^i2np\.udp\.inbound=/d' \
    -e '/^i2np\.udp\.host=/d' \
    -e '/^i2np\.udp\.port=/d' \
    -e '/^i2np\.ntcp\.enable=/d' \
    -e '/^i2np\.ntcp\.port=/d' \
    -e '/^i2np\.ntcp\.hostname=/d' \
    -e '/^i2np\.ntcp\.autoip=/d' \
    -e '/^i2np\.ntcp2\.enable=/d' \
    -e '/^i2np\.ntcp2\.port=/d' \
    -e '/^i2np\.ntcp2\.hostname=/d' \
    -e '/^i2np\.upnp\.enable=/d' \
    -e '/^# Network Configuration - Script/d' \
    -e '/^# Research Configuration/d' \
    "$ROUTER_CONFIG"

# Append the single authoritative transport block
cat >> "$ROUTER_CONFIG" << EOF

# Transport Configuration - Script 13 (authoritative)
# UDP (SSU2) - explicitly enabled; was never set by Scripts 03-06
i2np.udp.enable=true
i2np.udp.port=${I2P_PORT}
# NTCP2 - using correct I2P 2.x keys (ntcp2, not ntcp)
i2np.ntcp2.enable=true
i2np.ntcp2.port=${I2P_PORT}
i2np.ntcp2.hostname=
# UPnP disabled (not useful in VirtualBox/VPS)
i2np.upnp.enable=false
EOF

echo "  Done. Resulting transport lines:"
grep -E "i2np\.(udp|ntcp|upnp)" "$ROUTER_CONFIG" | sed 's/^/    /'
echo ""

# ============================================================================
# STEP 5: VirtualBox-specific fix
# Under VirtualBox NAT, I2P's inbound UDP probe always fails, causing I2P to
# self-disable UDP at runtime ("Firewalled with UDP Disabled").
# The workaround: set i2np.udp.requireIntroductions=false so the router uses
# SSU2 for outbound connections without waiting for inbound confirmation.
# ============================================================================
echo "[5/7] Applying VirtualBox NAT transport workaround..."

sed -i '/^i2np\.udp\.requireIntroductions=/d' "$ROUTER_CONFIG"
sed -i '/^i2np\.udp\.allowDirectToSelf=/d' "$ROUTER_CONFIG"

if [ "$VBOX" = true ]; then
    cat >> "$ROUTER_CONFIG" << 'EOF'

# VirtualBox NAT workaround - allow outbound SSU2 without inbound probe success
# Without this, I2P re-disables UDP at runtime when inbound UDP probe fails
i2np.udp.requireIntroductions=false
EOF
    echo "  VirtualBox NAT workaround applied."
else
    echo "  Not VirtualBox - skipping NAT workaround."
fi

# Fix ownership
chown "$RESEARCH_USER:$RESEARCH_USER" "$ROUTER_CONFIG"

# ============================================================================
# STEP 6: Firewall verification (port 24180 must be open for UDP)
# ============================================================================
echo "[6/7] Verifying UFW firewall..."
if command -v ufw &>/dev/null; then
    if ! ufw status | grep -q "${I2P_PORT}/udp"; then
        ufw allow ${I2P_PORT}/udp comment 'I2P SSU2 UDP' > /dev/null 2>&1
        echo "  Added: ${I2P_PORT}/udp"
    else
        echo "  OK: ${I2P_PORT}/udp already open"
    fi
    if ! ufw status | grep -q "${I2P_PORT}/tcp"; then
        ufw allow ${I2P_PORT}/tcp comment 'I2P NTCP2 TCP' > /dev/null 2>&1
        echo "  Added: ${I2P_PORT}/tcp"
    else
        echo "  OK: ${I2P_PORT}/tcp already open"
    fi
else
    echo "  UFW not found - skipping."
fi

# ============================================================================
# STEP 7: Start and verify
# ============================================================================
echo "[7/7] Starting I2P..."
systemctl start i2p.service
sleep 10

if systemctl is-active --quiet i2p.service; then
    echo "  I2P started successfully."
else
    echo "  ERROR: I2P failed to start."
    journalctl -u i2p.service -n 30 --no-pager
    exit 1
fi

echo ""
echo "=============================================================================="
echo "  WHAT TO EXPECT IN THE CONSOLE"
echo "=============================================================================="
echo ""
echo "  Wait 5-10 minutes then check http://127.0.0.1:7657"
echo ""
echo "  Status progression:"
echo "    'Firewalled with UDP Disabled'  → (old state, before this fix)"
echo "    'Testing'                        → (I2P probing reachability)"
echo "    'Firewalled'                     → ACCEPTABLE for VirtualBox NAT"
echo "    'OK'                             → only if inbound UDP is reachable"
echo ""
echo "  IMPORTANT - VirtualBox NAT:"
echo "    'Firewalled' (without 'UDP Disabled') is the correct final state"
echo "    under VirtualBox NAT. This means:"
echo "      - UDP transport IS active (SSU2 outbound works)"
echo "      - Inbound connections blocked by NAT (expected)"
echo "      - Router WILL build tunnels and participate in the network"
echo "      - Suitable for topology research and data collection"
echo ""
echo "  If you need full 'OK' status (inbound reachable), you need either:"
echo "    a) VirtualBox Settings → Network → Adapter → Bridged Adapter"
echo "    b) VirtualBox port forwarding: Host UDP ${I2P_PORT} → Guest UDP ${I2P_PORT}"
echo "       (Settings → Network → Advanced → Port Forwarding)"
echo ""
echo "=============================================================================="
echo "  Center of Anonymity Networks - University of Cincinnati"
echo "  Design by: Siddique Abubakar Muntaka"
echo "=============================================================================="
