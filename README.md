# WireGuard Manager and Installer

A simple Bash script to install, configure, and manage a WireGuard VPN server and clients on Debian-based Linux systems.

---

## Features

- **Automated installation** of WireGuard, iptables, and qrencode
- **Interactive setup**: choose outbound interface, generate server keys, and configure firewall rules
- **Easy client management**: add/remove clients, generate configs and QR codes for mobile devices
- **Safe uninstall**: removes only script-managed firewall rules and WireGuard configs, leaving existing firewall rules untouched
- **Tested on**: AWS EC2 and Oracle Cloud Infrastructure (OCI) instances running Debian/Ubuntu

---

## Requirements

- Debian-based Linux (Debian, Ubuntu, etc.)
- Root privileges
- Internet access for package installation

---

## Usage

1. **Download the script.**
2. **Run the script as root:**
    ```bash
    chmod +x wireguard.sh
    sudo ./wireguard.sh
    ```
3. **Follow the interactive menu** to install WireGuard, add clients, manage clients, or uninstall.

---

## Notes

- **IPv6 is not supported:** This script currently configures WireGuard and firewall rules for IPv4 only.
- The script only manages firewall rules it creates (marked with `WG_SCRIPT_MANAGED`).  
  It will not remove or modify any other iptables rules or the iptables package itself.
- All client configuration files are stored securely in `/etc/wireguard/clients/`.
- **You can send the client configuration file (e.g., `/etc/wireguard/clients/CLIENTNAME/CLIENTNAME.conf`) directly to the user, or use the QR code for mobile setup.**
- QR codes are generated for easy import into mobile WireGuard apps.

---

## Tested On

- AWS EC2 (Ubuntu 22.04, Debian 12)
- Oracle Cloud Infrastructure (OCI) Compute (Ubuntu 22.04)

---

## License

MIT License (see [LICENSE](LICENSE) file for details)

---

## Support

If you encounter any issues or have suggestions, please open an [issue](https://github.com/techtute/wireguard-manager/issues).

---

## Disclaimer

**Use at your own risk.** Always review scripts before running them on production systems.

---

### For Beginners

This script helps you set up a secure VPN in minutes.  
Just download, run, and follow the prompts—no Linux expertise required!
