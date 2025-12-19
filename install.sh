#!/bin/bash
set -euo pipefail

# Installation script for DuckDNS updater
# Supports: Ubuntu 24.04 LTS, Amazon Linux 2023
# Run with: sudo ./install.sh

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 
   exit 1
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

# 1. Copy configuration file
if [[ ! -f /etc/duckdns.conf ]]; then
    echo "→ Creating configuration file..."
    cp config/duckdns.conf.example /etc/duckdns.conf
    chown $DEFAULT_USER:$DEFAULT_USER /etc/duckdns.conf
    chmod 600 /etc/duckdns.conf
    echo "✓ Configuration file created at /etc/duckdns.conf"
    echo "⚠  IMPORTANT: Edit /etc/duckdns.conf and set your domain and token!"
    echo
else
    echo "⚠  /etc/duckdns.conf already exists, skipping..."
    echo
fi

# 2. Copy main script
echo "→ Installing main script..."
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
echo "→ Installing systemd service..."
# Replace USER placeholder with detected user
sed "s/User=ec2-user/User=$DEFAULT_USER/g; s/Group=ec2-user/Group=$DEFAULT_USER/g" \
    systemd/duckdns.service > /etc/systemd/system/duckdns.service
systemctl daemon-reload
echo "✓ Service installed"
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
echo "Next steps:"
echo "1. Edit configuration: sudo nano /etc/duckdns.conf"
echo "2. Start the service:   sudo systemctl start duckdns"
echo "3. Enable at boot:      sudo systemctl enable duckdns"
echo "4. Check status:        sudo systemctl status duckdns"
echo "5. View logs:           sudo journalctl -u duckdns -f"
echo
