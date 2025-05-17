#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Exit if not Debian-based
if [ ! -f /etc/debian_version ]; then
    echo -e "\n${RED}This script only supports Debian-based systems.${NC}\n"
    exit 1
fi

WG_DIR="/etc/wireguard"
WG_CLIENT_DIR="$WG_DIR/clients"
WG_MARKER="$WG_DIR/.installed_by_script"

# Check if required packages are installed
missing_dependencies() {
    for pkg in wg iptables qrencode; do
        if ! command -v "$pkg" &>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Check for pre-existing WireGuard or iptables config
pre_existing_check() {
    if [ -e "$WG_DIR/wg0.conf" ] || [ -e "$WG_DIR/privatekey" ]; then
        if [ ! -e "$WG_MARKER" ]; then
            echo -e "\n${RED}WireGuard appears to be already installed/configured on this system.${NC}"
            echo -e "${YELLOW}This script will only work safely on a clean system or one previously set up by this script.${NC}"
            echo -e "${RED}Please remove existing WireGuard configuration before proceeding.${NC}\n"
            exit 1
        fi
    fi
    # Only check iptables if installed
    if command -v iptables &>/dev/null; then
        if iptables -S | grep -qv 'WG_SCRIPT_MANAGED'; then
            if [ ! -e "$WG_MARKER" ] && [ -z "$WG_IGNORE_IPTABLES_CHECK" ]; then
                echo -e "\n${YELLOW}Existing iptables rules detected that were not set by this script.${NC}"
                echo -e "${YELLOW}These rules may conflict with rules added by this script.${NC}"
                while true; do
                    read -rp "$(echo -e "${CYAN}Do you want to ignore this warning and continue? [y/N]: ${NC}")" yn
                    case "$yn" in
                        [Yy]*) export WG_IGNORE_IPTABLES_CHECK=1; break ;;
                        [Nn]*|"") echo -e "\n${RED}Please clean up your iptables rules before proceeding.${NC}\n"; exit 1 ;;
                        *) echo -e "${YELLOW}Please answer yes or no.${NC}" ;;
                    esac
                done
            fi
        fi
    fi
}

# Choose outbound interface (excluding lo and wg0), show IPs
choose_interface() {
    local available_interfaces
    mapfile -t available_interfaces < <(ip -o -4 addr show | awk '$2 != "lo" && $2 != "wg0" {print $2 " (" $4 ")"}')
    if [ ${#available_interfaces[@]} -eq 0 ]; then
        echo -e "\n${RED}No available interfaces found to use as outbound interface!${NC}\n"
        exit 1
    fi

    echo -e "\n${CYAN}Available network interfaces:${NC}"
    local i=1
    for iface in "${available_interfaces[@]}"; do
        echo "  $i) $iface"
        ((i++))
    done

    while true; do
        read -rp "$(echo -e "${CYAN}Choose the outbound interface for WireGuard traffic [1-${#available_interfaces[@]}]: ${NC}")" idx
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#available_interfaces[@]}" ]; then
            INTERFACE=$(echo "${available_interfaces[$((idx-1))]}" | awk '{print $1}')
            break
        else
            echo -e "${YELLOW}Invalid selection.${NC}"
        fi
    done
    echo -e "\n${GREEN}Selected interface: $INTERFACE${NC}\n"
}

# Install WireGuard, qrencode, and iptables, and configure the server
install_wireguard() {
    pre_existing_check
    choose_interface

    WG_CONFIG="$WG_DIR/wg0.conf"

    echo -e "\n${BLUE}WireGuard not found or missing dependencies. Installing required packages...${NC}\n"
    apt update && apt install -y wireguard qrencode iptables

    echo -e "\n${GREEN}WireGuard and required packages have been installed successfully.${NC}\n"

    echo -e "${BLUE}Generating server keys...${NC}"
    umask 077
    mkdir -p "$WG_DIR"
    mkdir -p "$WG_CLIENT_DIR"
    chmod 700 "$WG_CLIENT_DIR"
    wg genkey | tee "$WG_DIR/privatekey" | wg pubkey > "$WG_DIR/publickey"

    # Prompt for port
    DEFAULT_PORT=51820
    read -rp "$(echo -e "${CYAN}Enter WireGuard listen port (default: $DEFAULT_PORT): ${NC}")" WG_PORT
    WG_PORT=${WG_PORT:-$DEFAULT_PORT}
    if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]] || [ "$WG_PORT" -lt 1 ] || [ "$WG_PORT" -gt 65535 ]; then
        echo -e "${YELLOW}Invalid port. Using default $DEFAULT_PORT.${NC}"
        WG_PORT=$DEFAULT_PORT
    fi
    echo "$WG_PORT" > "$WG_DIR/.port"

    echo -e "\n${BLUE}Creating wg0.conf file...${NC}\n"
    cat > "$WG_CONFIG" <<EOF
[Interface]
Address = 10.16.0.1/24
ListenPort = $WG_PORT
PrivateKey = $(cat "$WG_DIR/privatekey")

# Enable IP forwarding and set up firewall rules
PreUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A POSTROUTING -s 10.16.0.0/24 -o $INTERFACE -j MASQUERADE -m comment --comment WG_SCRIPT_MANAGED; iptables -A INPUT -i wg0 -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED; iptables -I FORWARD 1 -i $INTERFACE -o wg0 -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED; iptables -I FORWARD 1 -i wg0 -o $INTERFACE -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED; iptables -C INPUT -p udp --dport $WG_PORT -m state --state NEW -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport $WG_PORT -m state --state NEW -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED
PostDown = iptables -t nat -D POSTROUTING -s 10.16.0.0/24 -o $INTERFACE -j MASQUERADE -m comment --comment WG_SCRIPT_MANAGED; iptables -D INPUT -i wg0 -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED; iptables -D FORWARD -i $INTERFACE -o wg0 -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED; iptables -D FORWARD -i wg0 -o $INTERFACE -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED; iptables -D INPUT -p udp --dport $WG_PORT -m state --state NEW -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED
EOF

    echo -e "\n${BLUE}Enabling and starting WireGuard service...${NC}\n"
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0

    # Save interface selection for later use
    echo "$INTERFACE" > "$WG_DIR/.interface"
    touch "$WG_MARKER"

    # Add rules to /etc/iptables/rules.v4 if it exists
    if [ -f /etc/iptables/rules.v4 ]; then
        # INPUT rule for UDP port
        if ! grep -q "\-A INPUT \-p udp \-m state --state NEW \-m udp --dport $WG_PORT \-j ACCEPT" /etc/iptables/rules.v4; then
            sed -i "/\*filter/a -A INPUT -p udp -m state --state NEW -m udp --dport $WG_PORT -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED" /etc/iptables/rules.v4
        fi
        # FORWARD rules
        if ! grep -q "\-A FORWARD \-i wg0 \-o $INTERFACE \-j ACCEPT" /etc/iptables/rules.v4; then
            sed -i "/\*filter/a -A FORWARD -i wg0 -o $INTERFACE -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED" /etc/iptables/rules.v4
        fi
        if ! grep -q "\-A FORWARD \-i $INTERFACE \-o wg0 \-j ACCEPT" /etc/iptables/rules.v4; then
            sed -i "/\*filter/a -A FORWARD -i $INTERFACE -o wg0 -j ACCEPT -m comment --comment WG_SCRIPT_MANAGED" /etc/iptables/rules.v4
        fi
        # Restore iptables rules from rules.v4
        iptables-restore < /etc/iptables/rules.v4
    fi

    echo -e "\n${GREEN}WireGuard server setup is complete.${NC}\n"
}

# Function to add a new client
add_client() {
    if [ ! -f "$WG_DIR/.interface" ]; then
        echo -e "\n${RED}Unable to determine outbound interface. Please run install first.${NC}\n"
        return
    fi
    INTERFACE=$(cat "$WG_DIR/.interface")
    WG_PORT=$(cat "$WG_DIR/.port")

    mkdir -p "$WG_CLIENT_DIR"
    chmod 700 "$WG_CLIENT_DIR"

    while true; do
        read -rp "$(echo -e "${CYAN}Enter client name (no spaces, or E to exit): ${NC}")" CLIENT_NAME
        if [[ "$CLIENT_NAME" =~ ^[Ee]$ ]]; then
            return
        elif [[ ! "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo -e "${YELLOW}Invalid client name. Use only letters, numbers, underscores, or hyphens. No spaces allowed.${NC}"
        elif [ -d "$WG_CLIENT_DIR/$CLIENT_NAME" ]; then
            echo -e "${YELLOW}Client name already exists. Please choose a different name.${NC}"
        else
            break
        fi
    done

    CLIENT_DIR="$WG_CLIENT_DIR/$CLIENT_NAME"
    mkdir -p "$CLIENT_DIR"
    chmod 700 "$CLIENT_DIR"

    umask 077
    wg genkey | tee "$CLIENT_DIR/privatekey" | wg pubkey > "$CLIENT_DIR/publickey"

    CLIENT_PRIVATE_KEY=$(cat "$CLIENT_DIR/privatekey")
    CLIENT_PUBLIC_KEY=$(cat "$CLIENT_DIR/publickey")

    WG_CONFIG="$WG_DIR/wg0.conf"
    DEFAULT_PUBLIC_IP=$(curl -s ifconfig.me)
    read -rp "$(echo -e "${CYAN}Enter server endpoint public IP (default: $DEFAULT_PUBLIC_IP, or E to exit): ${NC}")" SERVER_PUBLIC_IP
    if [[ "$SERVER_PUBLIC_IP" =~ ^[Ee]$ ]]; then
        return
    fi
    SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-$DEFAULT_PUBLIC_IP}
    if [ -z "$SERVER_PUBLIC_IP" ]; then
        echo -e "${RED}No endpoint IP provided. Aborting.${NC}\n"
        return
    fi

    USED_IPS=$(grep -oP '10\.16\.0\.\d+' "$WG_CONFIG" || true)
    for i in {2..254}; do
        CLIENT_IP="10.16.0.$i"
        if ! echo "$USED_IPS" | grep -q "$CLIENT_IP"; then
            break
        fi
    done

    if [ -z "$CLIENT_IP" ]; then
        echo -e "${RED}No available IPs in the 10.16.0.0/24 subnet.${NC}\n"
        return
    fi

    cat > "$CLIENT_DIR/$CLIENT_NAME.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $(cat "$WG_DIR/publickey")
Endpoint = $SERVER_PUBLIC_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
EOF

    cat >> "$WG_CONFIG" <<EOF

# BEGIN $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32
# END $CLIENT_NAME
EOF

    systemctl restart wg-quick@wg0
    echo -e "\n${GREEN}Client $CLIENT_NAME added successfully!${NC}\n"
    echo -e "${CYAN}Configuration file path: $CLIENT_DIR/$CLIENT_NAME.conf${NC}\n"
    qrencode -t ansiutf8 < "$CLIENT_DIR/$CLIENT_NAME.conf"
    echo -e "\n${BLUE}QR code displayed above. You can scan it with your WireGuard client.${NC}\n"
}

# Delete a client
delete_client() {
    if [ ! -f "$WG_DIR/.interface" ]; then
        echo -e "\n${RED}Unable to determine outbound interface. Please run install first.${NC}\n"
        return
    fi

    CLIENT_NAME=$1
    CLIENT_DIR="$WG_CLIENT_DIR/$CLIENT_NAME"

    if [ ! -d "$CLIENT_DIR" ]; then
        echo -e "\n${YELLOW}Client $CLIENT_NAME does not exist!${NC}\n"
        return
    fi

    # Remove the [Peer] block for this client using the comment markers
    sed -i "/# BEGIN $CLIENT_NAME/,/# END $CLIENT_NAME/d" "$WG_DIR/wg0.conf"

    rm -rf "$CLIENT_DIR"
    systemctl restart wg-quick@wg0
    echo -e "\n${GREEN}Client $CLIENT_NAME deleted successfully!${NC}\n"
    read -rp "$(echo -e "${CYAN}Press Enter to return to the main menu...${NC}")"
}

# Manage clients
manage_clients() {
    if ! ls -1 "$WG_CLIENT_DIR" 2>/dev/null | grep -q .; then
        echo -e "\n${YELLOW}No clients found. Returning to the main menu.${NC}\n"
        return
    fi

    echo -e "\n${CYAN}Available clients:${NC}"
    ls -1 "$WG_CLIENT_DIR"
    echo

    read -rp "$(echo -e "${CYAN}Enter the client name to manage (or E to exit): ${NC}")" CLIENT_NAME
    if [[ "$CLIENT_NAME" =~ ^[Ee]$ ]]; then
        return
    fi
    if [ ! -d "$WG_CLIENT_DIR/$CLIENT_NAME" ]; then
        echo -e "\n${YELLOW}Invalid client name. Returning to the main menu.${NC}\n"
        return
    fi

    while true; do
        echo -e "\n${CYAN}What would you like to do with $CLIENT_NAME?${NC}"
        echo "(Q)R code"
        echo "(D)elete"
        echo "(E)xit"
        read -rp "$(echo -e "${CYAN}Choose an option: ${NC}")" OPTION
        case "${OPTION,,}" in
            q)
                echo -e "\n${BLUE}Generating QR code for $CLIENT_NAME...${NC}\n"
                qrencode -t ansiutf8 < "$WG_CLIENT_DIR/$CLIENT_NAME/$CLIENT_NAME.conf"
                echo -e "\n${CYAN}Configuration file path: $WG_CLIENT_DIR/$CLIENT_NAME/$CLIENT_NAME.conf${NC}\n"
                read -rp "$(echo -e "${CYAN}Press Enter to return to the previous menu...${NC}")"
                ;;
            d)
                delete_client "$CLIENT_NAME"
                break
                ;;
            e)
                break
                ;;
            *)
                echo -e "${YELLOW}Invalid option. Please enter Q, D, or E.${NC}"
                ;;
        esac
    done
}

# Uninstall everything installed by this script except iptables
uninstall_wireguard() {
    if [ ! -e "$WG_MARKER" ]; then
        echo -e "\n${RED}WireGuard was not installed by this script. Aborting uninstall.${NC}\n"
        exit 1
    fi
    systemctl stop wg-quick@wg0 || true
    systemctl disable wg-quick@wg0 || true
    apt remove --purge -y wireguard qrencode && apt autoremove -y
    rm -rf "$WG_DIR"
    # Remove only iptables rules with our comment from running config
    iptables-save | grep -v WG_SCRIPT_MANAGED | iptables-restore
    # Remove rules from /etc/iptables/rules.v4 if it exists
    if [ -f /etc/iptables/rules.v4 ]; then
        sed -i '/WG_SCRIPT_MANAGED/d' /etc/iptables/rules.v4
    fi
    echo -e "\n${GREEN}WireGuard, configurations and script-managed iptables rules removed.${NC}\n"
    echo -e "${YELLOW}WARNING: Iptables package was not removed. Only iptables rules created by this script (WG_SCRIPT_MANAGED) were removed.${NC}"
    echo -e "${YELLOW}This is to avoid disrupting any existing firewall configuration on your system.${NC}\n"
    exit 0
}

# Main menu
main_menu() {
    while true; do
        echo -e "\n${CYAN}WireGuard Management Script${NC}\n"
        if missing_dependencies; then
            echo "(I)nstall WireGuard and Configure Server"
            echo "(E)xit"
            read -rp "$(echo -e "${CYAN}Choose an option: ${NC}")" OPTION
            case "${OPTION,,}" in
                i) install_wireguard ;;
                e) exit 0 ;;
                *) echo -e "${YELLOW}Invalid option. Please enter I or E.${NC}" ;;
            esac
        else
            echo "(A)dd New Client"
            if ls -1 "$WG_CLIENT_DIR" 2>/dev/null | grep -q .; then
                echo "(M)anage Clients"
            fi
            if [ -e "$WG_MARKER" ]; then
                echo "(U)ninstall WireGuard and remove all configs"
            fi
            echo "(E)xit"
            read -rp "$(echo -e "${CYAN}Choose an option: ${NC}")" OPTION
            case "${OPTION,,}" in
                a) add_client ;;
                m) manage_clients ;;
                u) uninstall_wireguard ;;
                e) exit 0 ;;
                *) echo -e "${YELLOW}Invalid option. Please enter A, M, U, or E.${NC}" ;;
            esac
        fi
    done
}

# Exit if pre-existing WireGuard config not installed by this script
pre_existing_check

# Run the main menu
main_menu
