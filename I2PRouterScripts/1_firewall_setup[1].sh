#!/bin/bash

################################################################################
#                                                                              #
#  I2P Research Infrastructure - Script 3: Firewall Configuration             #
#                                                                              #
#  Design by: Siddique Abubakar Muntaka                                       #
#  University of Cincinnati, PhD Information Technology                       #
#  Advisor: Dr. Jacques Bou Abdo                                              #
#  Lab: Center of Anonymity Networks                                          #
#  School of Information Technology                                           #
#                                                                              #
#  Purpose: Configure UFW firewall with SSH, RDP, and I2P ports               #
#                                                                              #
################################################################################

set -e

I2P_PORT="24180"  # Standard I2P port (change if needed)

echo "=============================================================================="
echo "  I2P Research Infrastructure Deployment"
echo "  Script 3: Firewall Configuration"
echo "  Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Must run as root"
   exit 1
fi

echo "[1/5] Installing UFW firewall..."
DEBIAN_FRONTEND=noninteractive apt install -y -qq ufw

echo "[2/5] Configuring firewall rules..."
# SSH - Critical first!
ufw allow 22/tcp comment 'SSH access' > /dev/null 2>&1

# RDP for remote desktop
ufw allow 3389/tcp comment 'RDP access' > /dev/null 2>&1

# I2P router ports (both TCP and UDP)
ufw allow ${I2P_PORT}/udp comment 'I2P router SSU2' > /dev/null 2>&1
ufw allow ${I2P_PORT}/tcp comment 'I2P router NTCP2' > /dev/null 2>&1

echo "[3/5] Setting default policies..."
ufw --force enable > /dev/null 2>&1

echo "[4/5] Verifying firewall status..."
ufw status numbered

echo ""
echo "[5/5] Firewall configuration complete"
echo "  ✓ SSH (22/tcp) - Management access"
echo "  ✓ RDP (3389/tcp) - Remote desktop"
echo "  ✓ I2P (${I2P_PORT}/udp) - SSU2 router protocol"
echo "  ✓ I2P (${I2P_PORT}/tcp) - NTCP2 router protocol"
echo ""
echo "Run 04_java_i2p_install.sh next"
