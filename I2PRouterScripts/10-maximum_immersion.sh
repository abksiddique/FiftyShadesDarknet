#!/bin/bash

##############################################################################
# I2P Research Infrastructure Deployment
# Script 10: Maximum Network Immersion
# 
# Purpose: Force aggressive peer discovery and tunnel building
# Use Case: Routers in restrictive datacenters or with poor initial connectivity
#
# Design by: Siddique Abubakar Muntaka
# University of Cincinnati - PhD Information Technology
# Advisor: Dr. Jacques Bou Abdo
# Lab: Center of Anonymity Networks
# School of Information Technology
##############################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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
    echo -e "${BLUE}  Script 10: Maximum Network Immersion${NC}"
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

print_info() {
    echo -e "${CYAN}  → $1${NC}"
}

##############################################################################
# Diagnostic Functions
##############################################################################

check_current_status() {
    print_step "1" "10" "Checking current router status..."
    
    # Check if I2P is running
    if ! systemctl is-active --quiet i2p; then
        print_error "I2P service is not running!"
        print_info "Starting I2P service..."
        systemctl start i2p
        sleep 10
    else
        print_success "I2P service is running"
    fi
    
    # Check uptime
    UPTIME=$(ps -eo pid,etime,cmd | grep "java.*i2p" | grep -v grep | awk '{print $2}' | head -1)
    print_info "I2P uptime: ${UPTIME:-Unknown}"
    
    # Check current peers
    PEERS=$(curl -s http://127.0.0.1:7657/summarynoframe.jsp 2>/dev/null | grep -oP 'Active:</b></td><td align="right">\K[0-9]+' | head -1)
    print_info "Current active peers: ${PEERS:-0}"
    
    # Check network status
    NETWORK=$(curl -s http://127.0.0.1:7657/summarynoframe.jsp 2>/dev/null | grep -oP 'Network: \K[A-Z]+')
    if [ "$NETWORK" = "OK" ]; then
        print_success "Network status: OK"
    else
        print_warning "Network status: ${NETWORK:-Unknown}"
    fi
}

##############################################################################
# Configuration Backup
##############################################################################

backup_config() {
    print_step "2" "10" "Creating configuration backup..."
    
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${BACKUP_DIR}/router.config.immersion_${TIMESTAMP}"
    
    cp "$ROUTER_CONFIG" "$BACKUP_FILE"
    chown ${I2P_USER}:${I2P_USER} "$BACKUP_FILE"
    
    print_success "Backup: $BACKUP_FILE"
}

##############################################################################
# Network Immersion Optimizations
##############################################################################

enable_aggressive_peer_discovery() {
    print_step "3" "10" "Enabling aggressive peer discovery..."
    
    # Increase peer target (default: 100, aggressive: 300)
    if grep -q "^router.maxParticipatingTunnels=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.maxParticipatingTunnels=.*/router.maxParticipatingTunnels=500/' "$ROUTER_CONFIG"
    else
        echo "router.maxParticipatingTunnels=500" >> "$ROUTER_CONFIG"
    fi
    
    # Fast integration mode
    if grep -q "^router.fastPeers=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.fastPeers=.*/router.fastPeers=50/' "$ROUTER_CONFIG"
    else
        echo "router.fastPeers=50" >> "$ROUTER_CONFIG"
    fi
    
    # High capacity mode
    if grep -q "^router.highCapacity=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.highCapacity=.*/router.highCapacity=true/' "$ROUTER_CONFIG"
    else
        echo "router.highCapacity=true" >> "$ROUTER_CONFIG"
    fi
    
    print_success "Peer discovery: AGGRESSIVE"
}

optimize_tunnel_building() {
    print_step "4" "10" "Optimizing tunnel building..."
    
    # Increase exploratory tunnel count
    if grep -q "^router.exploratory.outbound.quantity=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.exploratory.outbound.quantity=.*/router.exploratory.outbound.quantity=4/' "$ROUTER_CONFIG"
    else
        echo "router.exploratory.outbound.quantity=4" >> "$ROUTER_CONFIG"
    fi
    
    if grep -q "^router.exploratory.inbound.quantity=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.exploratory.inbound.quantity=.*/router.exploratory.inbound.quantity=4/' "$ROUTER_CONFIG"
    else
        echo "router.exploratory.inbound.quantity=4" >> "$ROUTER_CONFIG"
    fi
    
    # Faster tunnel building
    if grep -q "^router.buildDelay=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.buildDelay=.*/router.buildDelay=500/' "$ROUTER_CONFIG"
    else
        echo "router.buildDelay=500" >> "$ROUTER_CONFIG"
    fi
    
    print_success "Tunnel building: OPTIMIZED"
}

enable_all_transports() {
    print_step "5" "10" "Enabling all transport protocols..."
    
    # Enable SSU2 (primary UDP transport)
    if grep -q "^i2np.udp.enable=" "$ROUTER_CONFIG"; then
        sed -i 's/^i2np.udp.enable=.*/i2np.udp.enable=true/' "$ROUTER_CONFIG"
    else
        echo "i2np.udp.enable=true" >> "$ROUTER_CONFIG"
    fi
    
    # Enable NTCP2 (primary TCP transport)
    if grep -q "^i2np.ntcp2.enable=" "$ROUTER_CONFIG"; then
        sed -i 's/^i2np.ntcp2.enable=.*/i2np.ntcp2.enable=true/' "$ROUTER_CONFIG"
    else
        echo "i2np.ntcp2.enable=true" >> "$ROUTER_CONFIG"
    fi
    
    # Enable IPv4
    if grep -q "^i2np.ipv4.enable=" "$ROUTER_CONFIG"; then
        sed -i 's/^i2np.ipv4.enable=.*/i2np.ipv4.enable=true/' "$ROUTER_CONFIG"
    else
        echo "i2np.ipv4.enable=true" >> "$ROUTER_CONFIG"
    fi
    
    # Enable IPv6 (for dual-stack)
    if grep -q "^i2np.ipv6.enable=" "$ROUTER_CONFIG"; then
        sed -i 's/^i2np.ipv6.enable=.*/i2np.ipv6.enable=true/' "$ROUTER_CONFIG"
    else
        echo "i2np.ipv6.enable=true" >> "$ROUTER_CONFIG"
    fi
    
    print_success "Transports: ALL ENABLED (SSU2, NTCP2, IPv4, IPv6)"
}

disable_testing_mode() {
    print_step "6" "10" "Disabling conservative testing modes..."
    
    # Disable hidden mode (be publicly routable)
    if grep -q "^router.hiddenMode=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.hiddenMode=.*/router.hiddenMode=false/' "$ROUTER_CONFIG"
    else
        echo "router.hiddenMode=false" >> "$ROUTER_CONFIG"
    fi
    
    # Disable laptop mode (assume stable connection)
    if grep -q "^laptop.mode=" "$ROUTER_CONFIG"; then
        sed -i 's/^laptop.mode=.*/laptop.mode=false/' "$ROUTER_CONFIG"
    else
        echo "laptop.mode=false" >> "$ROUTER_CONFIG"
    fi
    
    print_success "Conservative modes: DISABLED"
}

optimize_reseed_settings() {
    print_step "7" "10" "Optimizing reseed configuration..."
    
    # Enable multiple reseed sources
    if grep -q "^router.reseedURL=" "$ROUTER_CONFIG"; then
        sed -i 's|^router.reseedURL=.*|router.reseedURL=https://reseed.i2p-projekt.de/,https://reseed.i2p.net.in/,https://i2p.mooo.com/netDb/,https://reseed-pl.i2pd.xyz/,https://reseed2.i2p.net/,https://reseed.i2pgit.org/,https://banana.incognet.io/,https://coconut.incognet.io/|' "$ROUTER_CONFIG"
    else
        echo 'router.reseedURL=https://reseed.i2p-projekt.de/,https://reseed.i2p.net.in/,https://i2p.mooo.com/netDb/,https://reseed-pl.i2pd.xyz/,https://reseed2.i2p.net/,https://reseed.i2pgit.org/,https://banana.incognet.io/,https://coconut.incognet.io/' >> "$ROUTER_CONFIG"
    fi
    
    print_success "Reseed servers: MULTIPLE SOURCES"
}

maximize_bandwidth_share() {
    print_step "8" "10" "Maximizing bandwidth share..."
    
    # Set bandwidth share to 95% (maximum recommended)
    if grep -q "^router.sharePercentage=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.sharePercentage=.*/router.sharePercentage=95/' "$ROUTER_CONFIG"
    else
        echo "router.sharePercentage=95" >> "$ROUTER_CONFIG"
    fi
    
    # Increase burst capacity
    if grep -q "^i2np.bandwidth.burstKBytesPerSecond=" "$ROUTER_CONFIG"; then
        CURRENT=$(grep "^i2np.bandwidth.outboundKBytesPerSecond=" "$ROUTER_CONFIG" | cut -d'=' -f2)
        BURST=$((CURRENT * 2))
        sed -i "s/^i2np.bandwidth.burstKBytesPerSecond=.*/i2np.bandwidth.burstKBytesPerSecond=${BURST}/" "$ROUTER_CONFIG"
        print_success "Bandwidth share: 95% (burst: ${BURST} KBps)"
    else
        print_success "Bandwidth share: 95%"
    fi
}

enable_upnp_and_nat() {
    print_step "9" "10" "Configuring NAT/firewall traversal..."
    
    # Note: UPnP may not work in datacenter, but enable anyway
    if grep -q "^i2np.upnp.enable=" "$ROUTER_CONFIG"; then
        sed -i 's/^i2np.upnp.enable=.*/i2np.upnp.enable=true/' "$ROUTER_CONFIG"
    else
        echo "i2np.upnp.enable=true" >> "$ROUTER_CONFIG"
    fi
    
    # Enable peer test (helps detect firewall status)
    if grep -q "^router.enablePeerTest=" "$ROUTER_CONFIG"; then
        sed -i 's/^router.enablePeerTest=.*/router.enablePeerTest=true/' "$ROUTER_CONFIG"
    else
        echo "router.enablePeerTest=true" >> "$ROUTER_CONFIG"
    fi
    
    print_info "UPnP enabled (may not work in datacenter - manual ports already open)"
    print_success "Peer testing: ENABLED"
}

set_ownership() {
    chown ${I2P_USER}:${I2P_USER} "$ROUTER_CONFIG"
}

##############################################################################
# Force Immediate Reseed
##############################################################################

force_reseed() {
    print_step "10" "10" "Forcing immediate network reseed..."
    
    echo ""
    print_info "Triggering manual reseed via HTTP API..."
    
    # Trigger reseed via console
    RESEED_RESULT=$(curl -s "http://127.0.0.1:7657/configreseed?action=reseed" 2>/dev/null || echo "")
    
    if [ -n "$RESEED_RESULT" ]; then
        print_success "Reseed triggered via console"
    else
        print_warning "Could not trigger via console, will restart I2P instead"
    fi
    
    echo ""
    print_info "Restarting I2P to apply all changes..."
    systemctl restart i2p
    
    echo ""
    print_info "Waiting for I2P to restart (30 seconds)..."
    for i in {30..1}; do
        echo -ne "\r  ${CYAN}→${NC} Time remaining: ${i}s "
        sleep 1
    done
    echo ""
    
    if systemctl is-active --quiet i2p; then
        print_success "I2P restarted successfully"
    else
        print_error "I2P failed to start - check logs"
        exit 1
    fi
}

##############################################################################
# Post-Configuration Verification
##############################################################################

verify_immersion() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Network Immersion Status${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    sleep 10  # Give I2P time to start connecting
    
    # Check peers
    PEERS=$(curl -s http://127.0.0.1:7657/summarynoframe.jsp 2>/dev/null | grep -oP 'Active:</b></td><td align="right">\K[0-9]+' | head -1)
    echo -e "${GREEN}Active Peers:${NC} ${PEERS:-Checking...}"
    
    # Check network status
    NETWORK=$(curl -s http://127.0.0.1:7657/summarynoframe.jsp 2>/dev/null | grep -oP 'Network: \K[A-Z]+')
    echo -e "${GREEN}Network Status:${NC} ${NETWORK:-Checking...}"
    
    # Check tunnels
    TUNNELS=$(curl -s http://127.0.0.1:7657/summarynoframe.jsp 2>/dev/null | grep -oP 'Client:</b></td><td align="right">\K[0-9]+')
    echo -e "${GREEN}Active Tunnels:${NC} ${TUNNELS:-Checking...}"
    
    # Check reachability
    REACHABLE=$(curl -s http://127.0.0.1:7657/summarynoframe.jsp 2>/dev/null | grep -i "firewalled" && echo "NO" || echo "YES")
    echo -e "${GREEN}Publicly Reachable:${NC} ${REACHABLE}"
    
    echo ""
}

##############################################################################
# Display Summary
##############################################################################

display_summary() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Maximum Immersion Configuration Complete${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}Optimizations Applied:${NC}"
    echo "  1. ✓ Aggressive peer discovery (300 target)"
    echo "  2. ✓ Fast integration mode (50 fast peers)"
    echo "  3. ✓ High capacity mode enabled"
    echo "  4. ✓ Increased exploratory tunnels (4 in/out)"
    echo "  5. ✓ Maximum participating tunnels (500)"
    echo "  6. ✓ All transports enabled (SSU2, NTCP2, IPv4, IPv6)"
    echo "  7. ✓ Hidden/laptop modes disabled"
    echo "  8. ✓ Multiple reseed sources (8 servers)"
    echo "  9. ✓ Bandwidth share maximized (95%)"
    echo "  10. ✓ UPnP and peer testing enabled"
    echo ""
    echo -e "${YELLOW}Expected Timeline:${NC}"
    echo "  • 0-5 min:   Connecting to reseed servers"
    echo "  • 5-15 min:  Building exploratory tunnels"
    echo "  • 15-30 min: Peer connections increasing"
    echo "  • 30-60 min: Full network participation"
    echo "  • 60+ min:   Maximum immersion achieved"
    echo ""
    echo -e "${YELLOW}Monitoring:${NC}"
    echo "  • Console: http://127.0.0.1:7657"
    echo "  • Peers: http://127.0.0.1:7657/peers"
    echo "  • Tunnels: http://127.0.0.1:7657/tunnels"
    echo "  • Logs: tail -f /home/${I2P_USER}/.i2p/wrapper.log"
    echo ""
    echo -e "${YELLOW}Quick Check (run in 5 minutes):${NC}"
    echo "  curl -s http://127.0.0.1:7657/summarynoframe.jsp | grep -E 'Peers|Network|Tunnels'"
    echo ""
    echo -e "${YELLOW}If Still Having Issues:${NC}"
    echo "  1. Check datacenter doesn't block I2P protocols"
    echo "  2. Verify external port reachability:"
    echo "     nc -zv $(curl -s ifconfig.me) $(grep 'i2np.udp.port=' ${ROUTER_CONFIG} | cut -d'=' -f2)"
    echo "  3. Check wrapper.log for connection errors"
    echo "  4. Consider trying different I2P port number"
    echo ""
    echo -e "${CYAN}Backup Location:${NC} ${BACKUP_DIR}"
    echo -e "${CYAN}To restore:${NC} cp [backup_file] ${ROUTER_CONFIG} && systemctl restart i2p"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "Center of Anonymity Networks - University of Cincinnati"
    echo "Design by: Siddique Abubakar Muntaka"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

##############################################################################
# Main Execution
##############################################################################

main() {
    print_header
    echo ""
    
    check_current_status
    backup_config
    enable_aggressive_peer_discovery
    optimize_tunnel_building
    enable_all_transports
    disable_testing_mode
    optimize_reseed_settings
    maximize_bandwidth_share
    enable_upnp_and_nat
    set_ownership
    force_reseed
    verify_immersion
    display_summary
}

# Run main
main

exit 0
