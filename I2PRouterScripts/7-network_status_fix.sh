#!/bin/bash

################################################################################
#                                                                              #
#  I2P Research Infrastructure - Script 7: Network Status Fix                 #
#                                                                              #
#  Design by: Siddique Abubakar Muntaka                                       #
#  University of Cincinnati, PhD Information Technology                       #
#  Advisor: Dr. Jacques Bou Abdo                                              #
#  Lab: Center of Anonymity Networks                                          #
#  School of Information Technology                                           #
#                                                                              #
#  Purpose: Fix "Firewalled" status - enable proper port testing              #
#                                                                              #
################################################################################

set -e

RESEARCH_USER="sid"
CONFIG_DIR="/home/$RESEARCH_USER/.i2p"
ROUTER_CONFIG="$CONFIG_DIR/router.config"

echo "=============================================================================="
echo "  I2P Research Infrastructure Deployment"
echo "  Script 7: Network Firewall Status Fix"
echo "  Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Must run as root"
   exit 1
fi

echo "[1/6] Checking current network status..."
CURRENT_STATUS=$(grep -i "i2np.udp.inbound" "$ROUTER_CONFIG" 2>/dev/null || echo "not set")
echo "  Current inbound UDP setting: $CURRENT_STATUS"

echo "[2/6] Stopping I2P router..."
systemctl stop i2p.service
sleep 3

echo "[3/6] Enabling inbound connections..."
# Remove any existing inbound/firewalled overrides
sed -i '/i2np.udp.inbound=/d' "$ROUTER_CONFIG"
sed -i '/i2np.ntcp.autoip=/d' "$ROUTER_CONFIG"
sed -i '/i2np.upnp.enable=/d' "$ROUTER_CONFIG"

# Add proper network configuration
cat >> "$ROUTER_CONFIG" << 'EOF'

# Network Configuration - Script 7 Patch
# Enable inbound connections on both protocols
i2np.udp.inbound=true
i2np.ntcp.autoip=true
i2np.upnp.enable=false
EOF

echo "  ✓ Network settings updated"

echo "[4/6] Setting proper ownership..."
chown $RESEARCH_USER:$RESEARCH_USER "$ROUTER_CONFIG"

echo "[5/6] Starting I2P router..."
systemctl start i2p.service

echo "[6/6] Waiting for network status check..."
echo "  → I2P is now testing port reachability..."
echo "  → This takes 2-5 minutes"
sleep 10

if systemctl is-active --quiet i2p.service; then
    echo "  ✓ I2P router restarted successfully"
else
    echo "  ✗ I2P failed to restart"
    journalctl -u i2p.service -n 30 --no-pager
    exit 1
fi

echo ""
echo "=============================================================================="
echo "  ✓ NETWORK STATUS FIX APPLIED"
echo "=============================================================================="
echo ""
echo "Network Configuration:"
echo "  → Inbound UDP: ENABLED"
echo "  → Inbound NTCP2: ENABLED"
echo "  → UPnP: Disabled (VPS environment)"
echo "  → Firewall ports: 24180 TCP/UDP already open"
echo ""
echo "IMPORTANT:"
echo "  1. Wait 2-5 minutes for port testing to complete"
echo "  2. Refresh I2P console in browser"
echo "  3. Check 'Network' status - should change from 'Firewalled' to 'OK'"
echo "  4. If still shows 'Testing', wait another 5 minutes"
echo ""
echo "If after 10 minutes it still shows 'Firewalled':"
echo "  - Verify firewall: ufw status"
echo "  - Check router console at: http://127.0.0.1:7657/confignet"
echo "  - Manually test ports at: http://127.0.0.1:7657/confignet"
echo ""
echo "Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
