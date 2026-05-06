#!/bin/bash

#############################################################################
# I2P Client Tunnel Quantity Enhancement Script
# Author: Siddique Abubakar Muntaka
# Advisor: Dr. Jacques Bou Abdo
# Institution: University of Cincinnati
# Lab: Centre for Anonymity Networks
#
# Purpose: Increase client tunnel quantities for enhanced peer collection
# Target: Tunnel 0 (I2P HTTP Proxy - Shared Client)
#############################################################################

set -e  # Exit on error

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║       I2P CLIENT TUNNEL QUANTITY ENHANCEMENT SCRIPT               ║"
echo "║                                                                   ║"
echo "║  Author: Siddique Abubakar Muntaka                                ║"
echo "║  Advisor: Dr. Jacques Bou Abdo                                    ║"
echo "║  University of Cincinnati - Centre for Anonymity Networks         ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

#############################################################################
# Configuration Variables
#############################################################################

I2P_CONFIG_FILE="/home/sid/i2p/i2ptunnel.config"
BACKUP_DIR="/home/sid/i2p/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Tunnel quantities to set
INBOUND_QUANTITY=5
OUTBOUND_QUANTITY=5
INBOUND_BACKUP=2
OUTBOUND_BACKUP=2

# Which tunnels to modify
MODIFY_TUNNEL_0=true   # HTTP Proxy (shared client) - PRIMARY TARGET
MODIFY_TUNNEL_5=true   # HTTPS Proxy (connect client)
MODIFY_TUNNEL_6=true   # gitssh (already has 3, will increase to 10)

#############################################################################
# Function: Log messages
#############################################################################
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#############################################################################
# Function: Check if running as correct user
#############################################################################
check_user() {
    log_info "Checking user context..."
    CURRENT_USER=$(whoami)
    
    if [ "$CURRENT_USER" != "root" ] && [ "$CURRENT_USER" != "sid" ]; then
        log_warning "Running as: $CURRENT_USER"
        log_warning "This script should be run as root or sid"
    else
        log_success "Running as: $CURRENT_USER"
    fi
}

#############################################################################
# Function: Verify configuration file exists
#############################################################################
verify_config() {
    log_info "Verifying I2P configuration file..."
    
    if [ ! -f "$I2P_CONFIG_FILE" ]; then
        log_error "Configuration file not found: $I2P_CONFIG_FILE"
        exit 1
    fi
    
    log_success "Configuration file found"
}

#############################################################################
# Function: Create backup
#############################################################################
create_backup() {
    log_info "Creating backup of i2ptunnel.config..."
    
    mkdir -p "$BACKUP_DIR"
    cp "$I2P_CONFIG_FILE" "$BACKUP_DIR/i2ptunnel.config.backup_$TIMESTAMP"
    
    log_success "Backup created: $BACKUP_DIR/i2ptunnel.config.backup_$TIMESTAMP"
}

#############################################################################
# Function: Stop I2P router
#############################################################################
stop_i2p() {
    log_info "Stopping I2P router..."
    
    # Try to find the I2P router process
    if pgrep -f "i2p" > /dev/null; then
        # Check if running as systemd service
        if systemctl is-active --quiet i2p 2>/dev/null; then
            systemctl stop i2p
            log_success "I2P systemd service stopped"
        # Check for user service
        elif su - sid -c "systemctl --user is-active --quiet i2p" 2>/dev/null; then
            su - sid -c "systemctl --user stop i2p"
            log_success "I2P user service stopped"
        # Try direct command
        elif [ -f "/home/sid/i2p/i2prouter" ]; then
            su - sid -c "/home/sid/i2p/i2prouter stop"
            log_success "I2P router stopped via i2prouter command"
        else
            log_warning "I2P is running but couldn't determine stop method"
            log_warning "Please stop I2P manually, then press Enter to continue"
            read
        fi
        
        # Wait for process to fully stop
        sleep 5
    else
        log_warning "I2P doesn't appear to be running"
    fi
}

#############################################################################
# Function: Check if parameter exists for a tunnel
#############################################################################
param_exists() {
    local tunnel_num=$1
    local param_name=$2
    grep -q "^tunnel\.${tunnel_num}\.option\.${param_name}=" "$I2P_CONFIG_FILE"
}

#############################################################################
# Function: Add or update tunnel parameter
#############################################################################
set_tunnel_param() {
    local tunnel_num=$1
    local param_name=$2
    local param_value=$3
    local full_param="tunnel.${tunnel_num}.option.${param_name}"
    
    if param_exists "$tunnel_num" "$param_name"; then
        # Parameter exists, update it
        sed -i "s|^${full_param}=.*|${full_param}=${param_value}|" "$I2P_CONFIG_FILE"
        log_info "  Updated: ${full_param}=${param_value}"
    else
        # Parameter doesn't exist, add it after the tunnel's last option line
        # Find the last line for this tunnel
        local last_line=$(grep -n "^tunnel\.${tunnel_num}\." "$I2P_CONFIG_FILE" | tail -1 | cut -d: -f1)
        
        if [ -n "$last_line" ]; then
            sed -i "${last_line}a\\${full_param}=${param_value}" "$I2P_CONFIG_FILE"
            log_info "  Added: ${full_param}=${param_value}"
        else
            log_error "Could not find tunnel ${tunnel_num} in config file"
            return 1
        fi
    fi
}

#############################################################################
# Function: Modify tunnel quantities
#############################################################################
modify_tunnel() {
    local tunnel_num=$1
    local tunnel_name=$2
    
    echo ""
    log_info "Modifying Tunnel ${tunnel_num}: ${tunnel_name}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    set_tunnel_param "$tunnel_num" "inbound.quantity" "$INBOUND_QUANTITY"
    set_tunnel_param "$tunnel_num" "outbound.quantity" "$OUTBOUND_QUANTITY"
    set_tunnel_param "$tunnel_num" "inbound.backupQuantity" "$INBOUND_BACKUP"
    set_tunnel_param "$tunnel_num" "outbound.backupQuantity" "$OUTBOUND_BACKUP"
    
    # CRITICAL FIX: Prevent tunnels from reverting to 1 after idle
    set_tunnel_param "$tunnel_num" "i2cp.reduceOnIdle" "false"
    
    log_success "Tunnel ${tunnel_num} modified successfully"
}

#############################################################################
# Function: Display configuration summary
#############################################################################
display_summary() {
    echo ""
    log_info "Configuration Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Settings Applied to Each Modified Tunnel:"
    echo "    • Inbound quantity:        ${INBOUND_QUANTITY}"
    echo "    • Outbound quantity:       ${OUTBOUND_QUANTITY}"
    echo "    • Inbound backup:          ${INBOUND_BACKUP}"
    echo "    • Outbound backup:         ${OUTBOUND_BACKUP}"
    echo "    • Tunnel length:           3 hops (unchanged)"
    echo ""
    echo "  Expected Peers Per Tunnel:"
    echo "    • Active tunnels: $(( (INBOUND_QUANTITY + OUTBOUND_QUANTITY) * 3 )) peers"
    echo "    • With backups:   $(( (INBOUND_QUANTITY + OUTBOUND_QUANTITY + INBOUND_BACKUP + OUTBOUND_BACKUP) * 3 )) peers"
    echo ""
    echo "  Modified Tunnels:"
    if [ "$MODIFY_TUNNEL_0" = true ]; then
        echo "    ✓ Tunnel 0: I2P HTTP Proxy (Shared Client)"
    fi
    if [ "$MODIFY_TUNNEL_5" = true ]; then
        echo "    ✓ Tunnel 5: I2P HTTPS Proxy"
    fi
    if [ "$MODIFY_TUNNEL_6" = true ]; then
        echo "    ✓ Tunnel 6: gitssh.idk.i2p"
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

#############################################################################
# Function: Start I2P router
#############################################################################
start_i2p() {
    log_info "Starting I2P router..."
    
    # Try systemd first
    if systemctl list-unit-files | grep -q "^i2p.service"; then
        systemctl start i2p
        log_success "I2P systemd service started"
    # Try user service
    elif su - sid -c "systemctl --user list-unit-files" 2>/dev/null | grep -q "^i2p.service"; then
        su - sid -c "systemctl --user start i2p"
        log_success "I2P user service started"
    # Try direct command
    elif [ -f "/home/sid/i2p/i2prouter" ]; then
        su - sid -c "/home/sid/i2p/i2prouter start"
        log_success "I2P router started via i2prouter command"
    else
        log_warning "Could not automatically start I2P"
        log_warning "Please start I2P manually"
        return 1
    fi
    
    sleep 5
    log_info "Waiting for I2P router to initialize..."
}

#############################################################################
# Function: Verify changes
#############################################################################
verify_changes() {
    echo ""
    log_info "Verifying configuration changes..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ "$MODIFY_TUNNEL_0" = true ]; then
        echo ""
        echo -e "${CYAN}Tunnel 0 (HTTP Proxy):${NC}"
        grep "^tunnel\.0\.option\.\(inbound\|outbound\).*quantity=" "$I2P_CONFIG_FILE"
    fi
    
    if [ "$MODIFY_TUNNEL_5" = true ]; then
        echo ""
        echo -e "${CYAN}Tunnel 5 (HTTPS Proxy):${NC}"
        grep "^tunnel\.5\.option\.\(inbound\|outbound\).*quantity=" "$I2P_CONFIG_FILE"
    fi
    
    if [ "$MODIFY_TUNNEL_6" = true ]; then
        echo ""
        echo -e "${CYAN}Tunnel 6 (gitssh):${NC}"
        grep "^tunnel\.6\.option\.\(inbound\|outbound\).*quantity=" "$I2P_CONFIG_FILE"
    fi
    
    echo ""
    log_success "Verification complete"
}

#############################################################################
# Function: Display next steps
#############################################################################
display_next_steps() {
    echo ""
    log_info "Next Steps:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  1. Access I2P Router Console:"
    echo "     http://127.0.0.1:7657"
    echo ""
    echo "  2. Navigate to: Configuration → Tunnels"
    echo "     Verify tunnel quantities show: 10 inbound, 10 outbound"
    echo ""
    echo "  3. Wait 10-15 minutes for full tunnel establishment"
    echo ""
    echo "  4. Check tunnel status and peer connections"
    echo ""
    log_info "To restore previous configuration:"
    echo "  cp $BACKUP_DIR/i2ptunnel.config.backup_$TIMESTAMP $I2P_CONFIG_FILE"
    echo "  # Then restart I2P"
    echo ""
    log_success "Configuration enhancement completed!"
}

#############################################################################
# Main Execution
#############################################################################
main() {
    check_user
    verify_config
    create_backup
    stop_i2p
    
    # Modify tunnels
    if [ "$MODIFY_TUNNEL_0" = true ]; then
        modify_tunnel 0 "I2P HTTP Proxy"
    fi
    
    if [ "$MODIFY_TUNNEL_5" = true ]; then
        modify_tunnel 5 "I2P HTTPS Proxy"
    fi
    
    if [ "$MODIFY_TUNNEL_6" = true ]; then
        modify_tunnel 6 "gitssh.idk.i2p"
    fi
    
    display_summary
    verify_changes
    start_i2p
    display_next_steps
}

# Execute main function
main
