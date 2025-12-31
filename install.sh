#!/bin/bash
set -euo pipefail

# Installation script for DuckDNS updater
# Supports: Ubuntu 24.04 LTS, Amazon Linux 2023
# Run with: sudo ./install.sh [--force]

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 
   exit 1
fi

# Parse command line arguments
FORCE_INSTALL=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE_INSTALL=true
fi

echo "=== DuckDNS Updater Installation ==="
echo

# Detect the default user (ubuntu for Ubuntu, ec2-user for Amazon Linux)
if id ubuntu &>/dev/null; then
    DEFAULT_USER=ubuntu
elif id ec2-user &>/dev/null; then
    DEFAULT_USER=ec2-user
else
    echo "ERROR: Neither ubuntu nor ec2-user exists. Please edit install.sh manually."
    exit 1
fi

# Check if already installed
SERVICE_INSTALLED=false
CONFIG_EXISTS=false
SCRIPT_INSTALLED=false
SERVICE_RUNNING=false

if [[ -f /etc/systemd/system/duckdns.service ]]; then
    SERVICE_INSTALLED=true
fi

if [[ -f /etc/duckdns.conf ]]; then
    CONFIG_EXISTS=true
fi

if [[ -f /usr/local/bin/duckdns-update.sh ]]; then
    SCRIPT_INSTALLED=true
fi

if systemctl is-active --quiet duckdns 2>/dev/null; then
    SERVICE_RUNNING=true
fi

# Show installation status
if [[ "$SERVICE_INSTALLED" == true ]] || [[ "$CONFIG_EXISTS" == true ]] || [[ "$SCRIPT_INSTALLED" == true ]]; then
    echo "📋 Current installation status:"
    [[ "$CONFIG_EXISTS" == true ]] && echo "  • Configuration: /etc/duckdns.conf (exists)"
    [[ "$SCRIPT_INSTALLED" == true ]] && echo "  • Script: /usr/local/bin/duckdns-update.sh (exists)"
    [[ "$SERVICE_INSTALLED" == true ]] && echo "  • Service: duckdns.service (installed)"
    [[ "$SERVICE_RUNNING" == true ]] && echo "  • Status: Running" || echo "  • Status: Not running"
    echo
    
    if [[ "$FORCE_INSTALL" == false ]]; then
        echo "This appears to be an upgrade/reinstall."
        echo "The installer will:"
        echo "  • Preserve your existing /etc/duckdns.conf"
        echo "  • Update the script and service files"
        echo "  • Restart the service if it's running"
        echo
        read -p "Continue with upgrade? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Installation cancelled."
            exit 0
        fi
    fi
    
    # Stop service if running
    if [[ "$SERVICE_RUNNING" == true ]]; then
        echo "→ Stopping service for upgrade..."
        systemctl stop duckdns
        echo "✓ Service stopped"
        echo
    fi
fi

# 1. Handle configuration file
if [[ ! -f /etc/duckdns.conf ]]; then
    echo "→ Creating configuration file..."
    cp config/duckdns.conf.example /etc/duckdns.conf
    chown $DEFAULT_USER:$DEFAULT_USER /etc/duckdns.conf
    chmod 600 /etc/duckdns.conf
    echo "✓ Configuration file created at /etc/duckdns.conf"
    echo "⚠  IMPORTANT: Edit /etc/duckdns.conf and set your domain and token!"
    echo
else
    echo "→ Configuration file already exists"
    
    # Check if config has ENABLE_IPV6 setting (new feature)
    if ! grep -q "ENABLE_IPV6" /etc/duckdns.conf; then
        echo "  • Adding new IPv6 setting to existing config..."
        echo "" >> /etc/duckdns.conf
        echo "# Enable IPv6 support (default: true)" >> /etc/duckdns.conf
        echo "# Set to false if your EC2 instance doesn't have IPv6 or you don't want to update IPv6" >> /etc/duckdns.conf
        echo "ENABLE_IPV6=true" >> /etc/duckdns.conf
        echo "  ✓ Added ENABLE_IPV6=true to config"
    fi
    
    echo "✓ Keeping existing configuration"
    echo
fi

# 2. Copy main script
if [[ "$SCRIPT_INSTALLED" == true ]]; then
    echo "→ Updating main script..."
else
    echo "→ Installing main script..."
fi
cp bin/duck.sh /usr/local/bin/duckdns-update.sh
chmod +x /usr/local/bin/duckdns-update.sh
echo "✓ Script installed to /usr/local/bin/duckdns-update.sh"
echo

# 3. Create log file with proper permissions
echo "→ Setting up log file..."
touch /var/log/duckdns.log
chown $DEFAULT_USER:$DEFAULT_USER /var/log/duckdns.log
chmod 644 /var/log/duckdns.log
echo "✓ Log file created at /var/log/duckdns.log"
echo

# 4. Install systemd service
if [[ "$SERVICE_INSTALLED" == true ]]; then
    echo "→ Updating systemd service..."
else
    echo "→ Installing systemd service..."
fi
# Replace USER placeholder with detected user
sed "s/User=ec2-user/User=$DEFAULT_USER/g; s/Group=ec2-user/Group=$DEFAULT_USER/g" \
    systemd/duckdns.service > /etc/systemd/system/duckdns.service
systemctl daemon-reload
echo "✓ Service updated"
echo

# 5. Setup logrotate
echo "→ Setting up log rotation..."
cat > /etc/logrotate.d/duckdns <<EOF
/var/log/duckdns.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 $DEFAULT_USER $DEFAULT_USER
}
EOF
echo "✓ Log rotation configured"
echo

echo "=== Installation Complete! ==="
echo

# Restart service if it was running
if [[ "$SERVICE_RUNNING" == true ]]; then
    echo "→ Restarting service..."
    systemctl start duckdns
    sleep 2
    if systemctl is-active --quiet duckdns; then
        echo "✓ Service restarted successfully"
        echo
        echo "📊 Service status:"
        systemctl status duckdns --no-pager -l | head -n 10
        echo
        echo "💡 View live logs: sudo journalctl -u duckdns -f"
    else
        echo "⚠  Service failed to start. Check logs: sudo journalctl -u duckdns -n 50"
    fi
elif [[ "$CONFIG_EXISTS" == true ]]; then
    echo "Next steps:"
    echo "1. Review configuration: sudo nano /etc/duckdns.conf"
    echo "2. Start the service:    sudo systemctl start duckdns"
    echo "3. Enable at boot:       sudo systemctl enable duckdns"
    echo "4. View logs:            sudo journalctl -u duckdns -f"
else
    echo "Next steps:"
    echo "1. Edit configuration: sudo nano /etc/duckdns.conf"
    echo "2. Start the service:   sudo systemctl start duckdns"
    echo "3. Enable at boot:      sudo systemctl enable duckdns"
    echo "4. Check status:        sudo systemctl status duckdns"
    echo "5. View logs:           sudo journalctl -u duckdns -f"
fi
echo
