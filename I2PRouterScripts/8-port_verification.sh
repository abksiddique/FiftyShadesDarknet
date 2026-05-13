#!/bin/bash

################################################################################
#                                                                              #
#  I2P Research Infrastructure - Script 8: Port Verification & Sync           #
#                                                                              #
#  Design by: Siddique Abubakar Muntaka                                       #
#  University of Cincinnati, PhD Information Technology                       #
#  Advisor: Dr. Jacques Bou Abdo                                              #
#  Lab: Center of Anonymity Networks                                          #
#  School of Information Technology                                           #
#                                                                              #
#  Purpose: Verify I2P ports match firewall rules and fix mismatches          #
#                                                                              #
################################################################################

set -e

RESEARCH_USER="sid"
CONFIG_DIR="/home/$RESEARCH_USER/.i2p"
ROUTER_CONFIG="$CONFIG_DIR/router.config"

echo "=============================================================================="
echo "  I2P Research Infrastructure Deployment"
echo "  Script 8: Port Verification & Firewall Sync"
echo "  Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Must run as root"
   exit 1
fi

echo "[1/7] Detecting I2P router port..."

# Wait for I2P to be running
if ! systemctl is-active --quiet i2p.service; then
    echo "  ERROR: I2P service is not running"
    echo "  Start it with: systemctl start i2p.service"
    exit 1
fi

# Extract actual I2P port from config
I2P_PORT=$(grep "i2np.udp.port=" "$ROUTER_CONFIG" | cut -d'=' -f2)

if [ -z "$I2P_PORT" ]; then
    echo "  ERROR: Could not detect I2P port from config"
    exit 1
fi

echo "  ✓ I2P is using port: $I2P_PORT"

echo "[2/7] Checking if port is listening..."
if netstat -tulnp | grep -q ":$I2P_PORT"; then
    echo "  ✓ Port $I2P_PORT is active and listening"
else
    echo "  ✗ Port $I2P_PORT is NOT listening"
    echo "  Check I2P service status"
    exit 1
fi

echo "[3/7] Checking current firewall rules..."
CURRENT_RULES=$(ufw status numbered | grep "I2P router")

echo "  Current I2P firewall rules:"
echo "$CURRENT_RULES" | sed 's/^/    /'

echo "[4/7] Checking for port mismatches..."
if ufw status | grep -q "$I2P_PORT/udp.*I2P"; then
    echo "  ✓ Firewall already configured for port $I2P_PORT"
    NEEDS_UPDATE=false
else
    echo "  ✗ Firewall NOT configured for current I2P port $I2P_PORT"
    NEEDS_UPDATE=true
fi

if [ "$NEEDS_UPDATE" = true ]; then
    echo "[5/7] Removing old I2P firewall rules..."
    
    # Remove old I2P rules (looking for comment markers)
    OLD_RULES=$(ufw status numbered | grep "I2P router" | awk '{print $1}' | tr -d '[]' | sort -rn)
    
    for RULE_NUM in $OLD_RULES; do
        echo "  → Deleting rule #$RULE_NUM"
        echo "y" | ufw delete "$RULE_NUM" > /dev/null 2>&1
    done
    
    echo "[6/7] Adding correct I2P firewall rules..."
    ufw allow ${I2P_PORT}/udp comment 'I2P router SSU2' > /dev/null 2>&1
    ufw allow ${I2P_PORT}/tcp comment 'I2P router NTCP2' > /dev/null 2>&1
    echo "  ✓ Added firewall rules for port $I2P_PORT"
else
    echo "[5/7] No firewall changes needed"
    echo "[6/7] Firewall already correct"
fi

echo "[7/7] Final verification..."
echo ""
echo "=== FIREWALL STATUS ==="
ufw status verbose | grep -E "Status|Default|22|3389|$I2P_PORT"

echo ""
echo "=== I2P PORT STATUS ==="
echo "I2P Port: $I2P_PORT"
netstat -tulnp | grep java | grep -E "udp|tcp" | grep "$I2P_PORT"

echo ""
echo "=== EXTERNAL IP ==="
EXTERNAL_IP=$(curl -s -4 ifconfig.me)
echo "Your VPS IP: $EXTERNAL_IP"

echo ""
echo "=============================================================================="
echo "  ✓ PORT VERIFICATION COMPLETE"
echo "=============================================================================="
echo ""
echo "Summary:"
echo "  → I2P Port: $I2P_PORT (TCP + UDP)"
echo "  → Firewall: Configured and active"
echo "  → Status: Ready for external connections"
echo ""
echo "Next Steps:"
echo "  1. Wait 5-10 minutes for I2P to test port reachability"
echo "  2. Check I2P console Network status"
echo "  3. Should change from 'Testing' to 'OK'"
echo ""
echo "If Network status shows 'Firewalled' after 10 minutes:"
echo "  → Run Script 7 (07_network_status_fix.sh)"
echo ""
echo "Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
