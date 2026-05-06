#!/bin/bash

################################################################################
#                                                                              #
#  I2P Research Infrastructure - Script 4: Java & I2P Installation            #
#                                                                              #
#  Design by: Siddique Abubakar Muntaka                                       #
#  University of Cincinnati, PhD Information Technology                       #
#  Advisor: Dr. Jacques Bou Abdo                                              #
#  Lab: Center of Anonymity Networks                                          #
#  School of Information Technology                                           #
#                                                                              #
#  Purpose: Install Java, download I2P, verify checksum, and install          #
#                                                                              #
################################################################################

set -e

RESEARCH_USER="sid"
I2P_VERSION="2.10.0"
I2P_JAR="i2pinstall_${I2P_VERSION}.jar"
I2P_URL="https://files.i2p-projekt.de/${I2P_VERSION}/${I2P_JAR}"
I2P_SHA256="76372d552dddb8c1d751dde09bae64afba81fef551455e85e9275d3d031872ea"
INSTALL_DIR="/home/$RESEARCH_USER/i2p"

echo "=============================================================================="
echo "  I2P Research Infrastructure Deployment"
echo "  Script 4: Java & I2P Installation"
echo "  Center of Anonymity Networks - University of Cincinnati"
echo "=============================================================================="
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Must run as root"
   exit 1
fi

echo "[1/6] Installing Java Runtime Environment..."
DEBIAN_FRONTEND=noninteractive apt install -y -qq default-jre
JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
echo "  → Java $JAVA_VERSION installed"

echo "[2/6] Downloading I2P installer..."
cd /tmp
if [ -f "$I2P_JAR" ]; then
    echo "  → I2P installer already downloaded"
else
    wget -q --show-progress "$I2P_URL"
fi

echo "[3/6] Verifying checksum..."
COMPUTED_SHA256=$(sha256sum "$I2P_JAR" | awk '{print $1}')
if [ "$COMPUTED_SHA256" = "$I2P_SHA256" ]; then
    echo "  ✓ Checksum verified: VALID"
else
    echo "  ✗ Checksum verification FAILED!"
    echo "    Expected: $I2P_SHA256"
    echo "    Got:      $COMPUTED_SHA256"
    exit 1
fi

echo "[4/6] Installing I2P (console mode - automated)..."
# Run installer with automated inputs - CRITICAL: Use printf to avoid HEREDOC issues
printf "0\n1\n1\n$INSTALL_DIR\no\n1\n1\n" | java -jar "$I2P_JAR" -console

echo "[5/6] Setting ownership..."
chown -R $RESEARCH_USER:$RESEARCH_USER "$INSTALL_DIR"

echo "[6/6] Verifying installation..."
if [ -f "$INSTALL_DIR/i2prouter" ]; then
    echo "  ✓ I2P installed successfully"
    echo "  → Location: $INSTALL_DIR"
    echo "  → Owner: $RESEARCH_USER"
else
    echo "  ✗ Installation verification failed"
    exit 1
fi

echo ""
echo "✓ Script 4 complete"
echo "Run 05_i2p_configuration.sh next"
