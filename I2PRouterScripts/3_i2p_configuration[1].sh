#!/bin/bash

################################################################################
#                                                                              #
#  I2P Research Infrastructure - Script 5: I2P System Configuration           #
#                                                                              #
#  Design by: Siddique Abubakar Muntaka                                       #
#  University of Cincinnati, PhD Information Technology                       #
#  Advisor: Dr. Jacques Bou Abdo                                              #
#  Lab: Center of Anonymity Networks                                          #
#  School of Information Technology                                           #
#                                                                              #
#  Purpose: Fix I2P paths, create systemd service, enable auto-start          #
#                                                                              #
################################################################################

set -e

RESEARCH_USER="sid"
INSTALL_DIR="/home/$RESEARCH_USER/i2p"
CONFIG_DIR="/home/$RESEARCH_USER/.i2p"

echo "=============================================================================="
echo "  I2P Research Infrastructure Deployment"
echo "  Script 5: I2P Configuration & Service Setup"
echo "  Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Must run as root"
   exit 1
fi

echo "[1/4] Fixing I2P configuration paths (CRITICAL FIX)..."
# Fix hardcoded /root/.i2p paths in i2prouter script
sed -i 's|I2P_CONFIG_DIR="/root/Library/Application Support/i2p"|I2P_CONFIG_DIR="'$CONFIG_DIR'"|g' "$INSTALL_DIR/i2prouter"
sed -i 's|I2P_CONFIG_DIR="/root/.i2p"|I2P_CONFIG_DIR="'$CONFIG_DIR'"|g' "$INSTALL_DIR/i2prouter"

# Verify fixes
FIXED_COUNT=$(grep -c "I2P_CONFIG_DIR=\"$CONFIG_DIR\"" "$INSTALL_DIR/i2prouter")
echo "  ✓ Fixed $FIXED_COUNT path references"

echo "[2/4] Creating systemd service..."
cat > /etc/systemd/system/i2p.service << EOF
[Unit]
Description=I2P Router Service
After=network.target

[Service]
Type=forking
User=$RESEARCH_USER
WorkingDirectory=$INSTALL_DIR
Environment=HOME=/home/$RESEARCH_USER
PIDFile=$CONFIG_DIR/i2p.pid
ExecStart=$INSTALL_DIR/i2prouter start
ExecStop=$INSTALL_DIR/i2prouter stop
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[3/4] Enabling I2P service..."
systemctl daemon-reload
systemctl enable i2p.service --quiet

echo "[4/4] Starting I2P router..."
systemctl start i2p.service

# Wait for startup
echo "  → Waiting for I2P to start..."
sleep 5

# Verify service status
if systemctl is-active --quiet i2p.service; then
    echo "  ✓ I2P router is running"
    systemctl status i2p.service --no-pager -l | head -10
else
    echo "  ✗ I2P failed to start"
    journalctl -u i2p.service -n 20 --no-pager
    exit 1
fi

echo ""
echo "✓ Script 5 complete"
echo "  → I2P router: RUNNING"
echo "  → Console: http://127.0.0.1:7657"
echo "  → Auto-start: ENABLED"
echo ""
echo "Run 06_i2p_research_config.sh next for floodfill setup"
