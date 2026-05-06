#!/bin/bash

##############################################################################
# I2P Research Infrastructure Deployment
# Script 9: Convert Floodfill to Standard Router
# 
# Purpose: Disable floodfill mode and configure router as standard participant
# Use Case: For distributed topology research with non-floodfill nodes
#
# Design by: Siddique Abubakar Muntaka
# University of Cincinnati - PhD Information Technology
# Advisor: Dr. Jacques Bou Abdo
# Lab: Center of Anonymity Networks
# School of Information Technology
##############################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
I2P_USER="sid"
I2P_CONFIG_DIR="/home/${I2P_USER}/.i2p"
ROUTER_CONFIG="${I2P_CONFIG_DIR}/router.config"
BACKUP_DIR="${I2P_CONFIG_DIR}/backups"

##############################################################################
# Helper Functions
##############################################################################

print_header() {
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE}  I2P Research Infrastructure Deployment${NC}"
    echo -e "${BLUE}  Script 9: Convert Floodfill to Standard Router${NC}"
    echo -e "${BLUE}  Center of Anonymity Networks - University of Cincinnati${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
}

print_step() {
    echo -e "${GREEN}[$1/$2] $3${NC}"
}

print_warning() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}  ✗ $1${NC}"
}

print_success() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

##############################################################################
# Verification Functions
##############################################################################

verify_i2p_installed() {
    if [ ! -d "$I2P_CONFIG_DIR" ]; then
        print_error "I2P configuration directory not found at $I2P_CONFIG_DIR"
        print_error "Please run scripts 1-5 first to install I2P"
        exit 1
    fi

    if [ ! -f "$ROUTER_CONFIG" ]; then
        print_error "router.config not found at $ROUTER_CONFIG"
        print_error "I2P may not have been started yet"
        exit 1
    fi

    print_success "I2P installation verified"
}

verify_i2p_running() {
    if systemctl is-active --quiet i2p; then
        print_success "I2P service is running"
        return 0
    else
        print_warning "I2P service is not running"
        return 1
    fi
}

##############################################################################
# Backup Function
##############################################################################

backup_config() {
    print_step "1" "5" "Creating configuration backup..."
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Create timestamped backup
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${BACKUP_DIR}/router.config.backup_${TIMESTAMP}"
    
    cp "$ROUTER_CONFIG" "$BACKUP_FILE"
    chown ${I2P_USER}:${I2P_USER} "$BACKUP_FILE"
    
    print_success "Backup created: $BACKUP_FILE"
}

##############################################################################
# Configuration Functions
##############################################################################

disable_floodfill() {
    print_step "2" "5" "Disabling floodfill mode..."
    
    # Remove or set floodfill to false
    if grep -q "^router.floodfillParticipant=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.floodfillParticipant=.*/router.floodfillParticipant=false/' "$ROUTER_CONFIG"
        print_success "Floodfill mode disabled (set to false)"
    else
        echo "router.floodfillParticipant=false" >> "$ROUTER_CONFIG"
        print_success "Floodfill mode disabled (added setting)"
    fi
}

configure_standard_bandwidth() {
    print_step "3" "5" "Configuring standard router bandwidth..."
    
    # Set moderate bandwidth limits for standard router
    # These are more conservative than floodfill settings
    
    # Inbound bandwidth: 512 KBps (4 Mbps)
    if grep -q "^i2np.bandwidth.inboundKBytesPerSecond=" "$ROUTER_CONFIG"; then
        sed -i 's/^i2np.bandwidth.inboundKBytesPerSecond=.*/i2np.bandwidth.inboundKBytesPerSecond=512/' "$ROUTER_CONFIG"
    else
        echo "i2np.bandwidth.inboundKBytesPerSecond=512" >> "$ROUTER_CONFIG"
    fi
    
    # Outbound bandwidth: 512 KBps (4 Mbps)
    if grep -q "^i2np.bandwidth.outboundKBytesPerSecond=" "$ROUTER_CONFIG"; then
        sed -i 's/^i2np.bandwidth.outboundKBytesPerSecond=.*/i2np.bandwidth.outboundKBytesPerSecond=512/' "$ROUTER_CONFIG"
    else
        echo "i2np.bandwidth.outboundKBytesPerSecond=512" >> "$ROUTER_CONFIG"
    fi
    
    # Burst bandwidth: 768 KBps (6 Mbps)
    if grep -q "^i2np.bandwidth.burstKBytesPerSecond=" "$ROUTER_CONFIG"; then
        sed -i 's/^i2np.bandwidth.burstKBytesPerSecond=.*/i2np.bandwidth.burstKBytesPerSecond=768/' "$ROUTER_CONFIG"
    else
        echo "i2np.bandwidth.burstKBytesPerSecond=768" >> "$ROUTER_CONFIG"
    fi
    
    print_success "Bandwidth configured:"
    print_success "  → Inbound: 512 KBps (4 Mbps)"
    print_success "  → Outbound: 512 KBps (4 Mbps)"
    print_success "  → Burst: 768 KBps (6 Mbps)"
}

configure_standard_share() {
    print_step "4" "5" "Configuring standard bandwidth share percentage..."
    
    # Standard routers typically share 80% of bandwidth
    # (Floodfills often share 90%+)
    
    if grep -q "^router.sharePercentage=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.sharePercentage=.*/router.sharePercentage=80/' "$ROUTER_CONFIG"
    else
        echo "router.sharePercentage=80" >> "$ROUTER_CONFIG"
    fi
    
    print_success "Bandwidth share set to 80%"
}

set_ownership() {
    print_step "5" "5" "Setting correct file ownership..."
    
    chown ${I2P_USER}:${I2P_USER} "$ROUTER_CONFIG"
    
    print_success "Ownership set to ${I2P_USER}"
}

##############################################################################
# I2P Service Management
##############################################################################

restart_i2p() {
    echo ""
    echo -e "${YELLOW}Configuration changes require I2P restart to take effect${NC}"
    echo -e "${YELLOW}Restarting I2P service...${NC}"
    echo ""
    
    systemctl restart i2p
    
    echo -e "${GREEN}  → Waiting for I2P to restart...${NC}"
    sleep 10
    
    if systemctl is-active --quiet i2p; then
        print_success "I2P router restarted successfully"
    else
        print_error "I2P failed to start"
        print_warning "Check logs: journalctl -u i2p -n 50"
        exit 1
    fi
}

##############################################################################
# Verification Functions
##############################################################################

verify_configuration() {
    echo ""
    echo -e "${BLUE}Verifying new configuration...${NC}"
    echo ""
    
    # Check floodfill status
    FF_STATUS=$(grep "^router.floodfillParticipant=" "$ROUTER_CONFIG" | cut -d'=' -f2)
    if [ "$FF_STATUS" = "false" ]; then
        print_success "Floodfill: DISABLED"
    else
        print_warning "Floodfill status unclear: $FF_STATUS"
    fi
    
    # Check bandwidth settings
    INBOUND=$(grep "^i2np.bandwidth.inboundKBytesPerSecond=" "$ROUTER_CONFIG" | cut -d'=' -f2)
    OUTBOUND=$(grep "^i2np.bandwidth.outboundKBytesPerSecond=" "$ROUTER_CONFIG" | cut -d'=' -f2)
    BURST=$(grep "^i2np.bandwidth.burstKBytesPerSecond=" "$ROUTER_CONFIG" | cut -d'=' -f2)
    SHARE=$(grep "^router.sharePercentage=" "$ROUTER_CONFIG" | cut -d'=' -f2)
    
    echo -e "${GREEN}Current Settings:${NC}"
    echo "  → Inbound: ${INBOUND} KBps"
    echo "  → Outbound: ${OUTBOUND} KBps"
    echo "  → Burst: ${BURST} KBps"
    echo "  → Share: ${SHARE}%"
}

display_summary() {
    echo ""
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${GREEN}✓ Script 9 complete${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
    echo ""
    echo -e "${GREEN}Configuration Changes:${NC}"
    echo "  1. Floodfill mode: DISABLED"
    echo "  2. Router type: STANDARD PARTICIPANT"
    echo "  3. Bandwidth limits: 512/512 KBps (in/out)"
    echo "  4. Bandwidth share: 80%"
    echo ""
    echo -e "${YELLOW}Network Integration Timeline:${NC}"
    echo "  • 0-15 min: Connecting to bootstrap nodes"
    echo "  • 15-30 min: Building exploratory tunnels"
    echo "  • 30-60 min: Participating in network tunnels"
    echo "  • 60+ min: Full network integration as standard router"
    echo ""
    echo -e "${YELLOW}Expected Behavior:${NC}"
    echo "  → Will NOT store netDB entries from other routers"
    echo "  → Will participate in tunnel building"
    echo "  → Will route traffic for other routers"
    echo "  → Lower bandwidth requirements than floodfill"
    echo "  → Suitable for topology research as network participant"
    echo ""
    echo -e "${GREEN}Monitoring:${NC}"
    echo "  • Console: http://127.0.0.1:7657"
    echo "  • Status: systemctl status i2p"
    echo "  • Logs: tail -f /home/${I2P_USER}/.i2p/wrapper.log"
    echo ""
    echo -e "${YELLOW}Configuration Backup:${NC}"
    echo "  • Location: $BACKUP_DIR"
    echo "  • To restore: cp [backup_file] $ROUTER_CONFIG && systemctl restart i2p"
    echo ""
    echo -e "${BLUE}==============================================================================${NC}"
    echo "Center of Anonymity Networks - University of Cincinnati"
    echo "Design by: Siddique Abubakar Muntaka"
    echo -e "${BLUE}==============================================================================${NC}"
}

##############################################################################
# Main Execution
##############################################################################

main() {
    print_header
    echo ""
    
    # Verify I2P is installed
    verify_i2p_installed
    
    # Check if I2P is running (just for info)
    I2P_WAS_RUNNING=0
    if verify_i2p_running; then
        I2P_WAS_RUNNING=1
    fi
    
    echo ""
    
    # Execute configuration steps
    backup_config
    disable_floodfill
    configure_standard_bandwidth
    configure_standard_share
    set_ownership
    
    # Restart I2P to apply changes
    restart_i2p
    
    # Verify configuration
    verify_configuration
    
    # Display summary
    display_summary
}

# Run main function
main

exit 0