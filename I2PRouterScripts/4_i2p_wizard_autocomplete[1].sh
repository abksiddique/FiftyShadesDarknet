#!/bin/bash

################################################################################
#                                                                              #
#  I2P First-Run Wizard Auto-Completion Script                                #
#                                                                              #
#  Design by: Siddique Abubakar Muntaka                                       #
#  University of Cincinnati, PhD Information Technology                       #
#  Advisor: Dr. Jacques Bou Abdo                                              #
#  Lab: Center of Anonymity Networks                                          #
#  School of Information Technology                                           #
#                                                                              #
#  Purpose: Automatically complete I2P wizard for standard (non-floodfill)    #
#           routers. Eliminates manual "Next, Next, Next..." clicking.        #
#                                                                              #
#  Usage: sudo bash 05b_i2p_wizard_autocomplete.sh                            #
#                                                                              #
################################################################################

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
I2P_DIR="/home/${I2P_USER}/.i2p"
ROUTER_CONFIG="${I2P_DIR}/router.config"

##############################################################################
# Helper Functions
##############################################################################

print_header() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  I2P First-Run Wizard Auto-Completion (PROVEN METHOD)${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Design by: Siddique Abubakar Muntaka${NC}"
    echo -e "${CYAN}Center of Anonymity Networks - University of Cincinnati${NC}"
    echo -e "${CYAN}Advisor: Dr. Jacques Bou Abdo${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${CYAN}→ $1${NC}"
}

verify_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        echo -e "${YELLOW}Please run: sudo bash $0${NC}"
        exit 1
    fi
}

verify_i2p_installed() {
    if [ ! -f "${ROUTER_CONFIG}" ]; then
        print_error "I2P configuration not found at ${ROUTER_CONFIG}"
        print_error "Please ensure I2P is installed and has been started at least once"
        exit 1
    fi
    print_success "I2P configuration found"
}

##############################################################################
# Main Configuration (PROVEN WORKING METHOD from Script 6)
##############################################################################

configure_wizard_bypass() {
    echo ""
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}Configuring Wizard Bypass (Using Proven Method)${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    print_info "Stopping I2P service..."
    systemctl stop i2p
    sleep 3
    print_success "I2P stopped"
    
    print_info "Adding wizard completion flag to router.config..."
    
    # Check if flag already exists
    if grep -q "^routerconsole.welcomeWizardComplete=" "${ROUTER_CONFIG}"; then
        print_info "Flag already exists, updating value..."
        sed -i 's/^routerconsole.welcomeWizardComplete=.*/routerconsole.welcomeWizardComplete=true/' "${ROUTER_CONFIG}"
    else
        print_info "Adding new flag..."
        echo "routerconsole.welcomeWizardComplete=true" >> "${ROUTER_CONFIG}"
    fi
    
    print_success "Wizard completion flag added"
    
    print_info "Setting file permissions..."
    chown ${I2P_USER}:${I2P_USER} "${ROUTER_CONFIG}"
    print_success "Permissions set"
    
    print_info "Starting I2P service..."
    systemctl start i2p
    sleep 10
    print_success "I2P started"
}

verify_wizard_disabled() {
    echo ""
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}Verifying Configuration${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    if grep -q "^routerconsole.welcomeWizardComplete=true" "${ROUTER_CONFIG}"; then
        print_success "Wizard completion flag verified in router.config"
    else
        print_error "Warning: Flag not found in router.config"
    fi
    
    if systemctl is-active --quiet i2p; then
        print_success "I2P service is running"
    else
        print_error "I2P service is not running"
    fi
    
    print_info "Waiting for console to become available..."
    sleep 5
    
    if curl -s http://127.0.0.1:7657/ > /dev/null 2>&1; then
        print_success "I2P console is accessible"
    else
        echo -e "${YELLOW}⚠ Console not yet responding (may need more time)${NC}"
    fi
}

display_summary() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  WIZARD AUTO-COMPLETION COMPLETE${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Configuration Applied:${NC}"
    echo -e "  ${GREEN}✓${NC} Wizard bypass flag added to router.config"
    echo -e "  ${GREEN}✓${NC} I2P service restarted"
    echo -e "  ${GREEN}✓${NC} Permissions configured"
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo ""
    echo -e "  ${YELLOW}1.${NC} Access I2P console via RDP browser:"
    echo -e "     ${GREEN}http://127.0.0.1:7657/${NC}"
    echo -e "     ${CYAN}The wizard should NOT appear!${NC}"
    echo ""
    echo -e "  ${YELLOW}2.${NC} If network shows 'Firewalled', run:"
    echo -e "     ${GREEN}sudo bash 07_network_status_fix.sh${NC}"
    echo ""
    echo -e "  ${YELLOW}3.${NC} Verify port connectivity:"
    echo -e "     ${GREEN}sudo bash 08_port_verification.sh${NC}"
    echo ""
    echo -e "  ${YELLOW}4.${NC} Allow 15-30 minutes for network integration"
    echo ""
    echo -e "${CYAN}Troubleshooting:${NC}"
    echo ""
    echo -e "  If wizard still appears:"
    echo -e "    • Clear browser cache and reload"
    echo -e "    • Try incognito/private browsing mode"
    echo -e "    • Verify: grep welcomeWizardComplete /home/sid/.i2p/router.config"
    echo ""
    echo -e "  Check logs if issues:"
    echo -e "    ${GREEN}tail -f /home/sid/.i2p/wrapper.log${NC}"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Script 05b Complete - Wizard Bypass Configured${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Design by: Siddique Abubakar Muntaka${NC}"
    echo -e "${CYAN}Center of Anonymity Networks - University of Cincinnati${NC}"
    echo -e "${CYAN}Advisor: Dr. Jacques Bou Abdo${NC}"
    echo ""
}

##############################################################################
# Main Execution
##############################################################################

main() {
    print_header
    verify_root
    verify_i2p_installed
    configure_wizard_bypass
    verify_wizard_disabled
    display_summary
}

# Execute main function
main

exit 0
