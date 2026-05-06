#!/bin/bash

################################################################################
#                                                                              #
#  I2P Research Infrastructure - Script 6: Research-Grade Configuration       #
#                                                                              #
#  Design by: Siddique Abubakar Muntaka                                       #
#  University of Cincinnati, PhD Information Technology                       #
#  Advisor: Dr. Jacques Bou Abdo                                              #
#  Lab: Center of Anonymity Networks                                          #
#  School of Information Technology                                           #
#                                                                              #
#  Purpose: Configure I2P for research: bandwidth, floodfill, auto-config     #
#                                                                              #
################################################################################

set -e

RESEARCH_USER="sid"
CONFIG_DIR="/home/$RESEARCH_USER/.i2p"
ROUTER_CONFIG="$CONFIG_DIR/router.config"

echo "=============================================================================="
echo "  I2P Research Infrastructure Deployment"
echo "  Script 6: Research-Grade I2P Configuration"
echo "  Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Must run as root"
   exit 1
fi

echo "[1/6] Stopping I2P for configuration..."
systemctl stop i2p.service

echo "[2/6] Waiting for I2P to fully stop..."
sleep 3

echo "[3/6] Pre-configuring fixed port 24180 (CRITICAL FOR REPRODUCIBILITY)..."
# Remove any existing port configuration
sed -i '/i2np.udp.port=/d' "$ROUTER_CONFIG"
sed -i '/i2np.udp.host=/d' "$ROUTER_CONFIG"
sed -i '/i2np.ntcp.port=/d' "$ROUTER_CONFIG"

echo "[4/6] Applying research configuration..."
# Add bandwidth and research settings to router.config
cat >> "$ROUTER_CONFIG" << 'EOF'

# Research Configuration - Center of Anonymity Networks
# Configured for high-bandwidth VPS deployment

# FIXED PORT CONFIGURATION - For Scientific Reproducibility
# All research routers use port 24180 (matches firewall configuration)
i2np.udp.port=24180
i2np.udp.host=0.0.0.0
i2np.ntcp.port=24180
i2np.ntcp.hostname=

# Bandwidth Configuration (1Gbps VPS)
i2np.bandwidth.inboundBurstKBytes=1473086
i2np.bandwidth.inboundBurstKBytesPerSecond=73654
i2np.bandwidth.inboundKBytesPerSecond=73604
i2np.bandwidth.outboundBurstKBytes=1483535
i2np.bandwidth.outboundBurstKBytesPerSecond=74177
i2np.bandwidth.outboundKBytesPerSecond=74127
router.sharePercentage=80

# Console settings
routerconsole.country=
routerconsole.lang=en
routerconsole.newsLastNewEntry=0
routerconsole.theme=light
routerconsole.welcomeWizardComplete=true

# Floodfill configuration for research
router.floodfillParticipant=true
router.minFloodfillPeers=200
EOF

echo "  ✓ Configuration applied"
echo "  ✓ Port 24180 pre-configured (TCP + UDP)"

echo "[5/6] Setting permissions..."
chown $RESEARCH_USER:$RESEARCH_USER "$ROUTER_CONFIG"

echo "[6/6] Starting I2P with research configuration..."
systemctl start i2p.service

# Wait and verify
sleep 10

if systemctl is-active --quiet i2p.service; then
    echo "  ✓ I2P router started successfully"
else
    echo "  ✗ I2P failed to start with new config"
    journalctl -u i2p.service -n 30 --no-pager
    exit 1
fi

echo ""
echo "=============================================================================="
echo "  ✓ I2P RESEARCH INFRASTRUCTURE DEPLOYMENT COMPLETE"
echo "=============================================================================="
echo ""
echo "Configuration Summary:"
echo "  → User: $RESEARCH_USER"
echo "  → I2P Console: http://127.0.0.1:7657"
echo "  → RDP Access: Port 3389"
echo "  → I2P Router Port: 24180 (TCP/UDP)"
echo "  → Bandwidth: ~73 MB/s (high-capacity node)"
echo "  → Floodfill: ENABLED (requires 2+ hours uptime)"
echo "  → Firewall: UFW active (SSH, RDP, I2P)"
echo ""
echo "Next Steps:"
echo "  1. Access via RDP to view I2P console"
echo "  2. Allow 1-2 hours for full network integration"
echo "  3. Monitor participating tunnels in console"
echo "  4. Begin research data collection"
echo ""
echo "Center of Anonymity Networks - University of Cincinnati"
echo "Design by: Siddique Abubakar Muntaka"
echo "=============================================================================="