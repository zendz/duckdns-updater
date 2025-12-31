# DuckDNS Dynamic DNS Updater for AWS EC2

## Overview
Production-ready dynamic DNS updater for DuckDNS running on AWS EC2. Supports **Ubuntu 24.04 LTS** and **Amazon Linux 2023**. Automatically monitors public IP changes via EC2 Instance Metadata Service (IMDSv2) and updates DuckDNS records with error handling, retry logic, and systemd integration.

## Architecture

### Components
- **[bin/duck.sh](bin/duck.sh)**: Main updater script with IMDSv2 support, response validation, and exponential backoff
- **[systemd/duckdns.service](systemd/duckdns.service)**: systemd service unit with security hardening and auto-restart
- **[config/duckdns.conf.example](config/duckdns.conf.example)**: Configuration template for `/etc/duckdns.conf`
- **[install.sh](install.sh)**: Automated installer with auto-detection for Ubuntu/Amazon Linux

### Why systemd? (Not Cron)
The official DuckDNS EC2 documentation suggests using cron with a 5-minute interval. **This approach has a critical flaw**: when an EC2 instance restarts and receives a new public IP, **it can take up to 5 minutes before the DNS record is updated**. During this window, your domain points to the old IP address, causing service downtime.

Our systemd-based solution solves this by:
- **Immediate updates on boot**: Service starts automatically and updates DNS within seconds
- **Continuous monitoring**: Detects IP changes instantly (configurable interval, default 5min)
- **Automatic recovery**: Restarts on failures, ensuring the updater is always running
- **Better logging**: Integrated with journald for centralized log management

### Key Improvements Over DuckDNS Docs
- **IMDSv2 token authentication**: More secure than `ec2metadata` command
- **Response validation**: Checks for `OK`/`KO` responses from API
- **Retry logic**: Exponential backoff on network failures
- **Proper logging**: Timestamps and log rotation via logrotate
- **Security**: No hardcoded credentials, proper file permissions (600)
- **systemd integration**: Auto-restart, boot persistence, journal logging
- **Cross-platform**: Auto-detects Ubuntu (`ubuntu` user) or Amazon Linux (`ec2-user`)

## Installation

### Quick Setup (New Installation)
```bash
sudo ./install.sh
sudo nano /etc/duckdns.conf  # Set your domain and token
sudo systemctl start duckdns
sudo systemctl enable duckdns
```

### Upgrade Existing Installation
```bash
# The installer automatically detects existing installations
sudo ./install.sh

# Or force reinstall without prompts
sudo ./install.sh --force
```

**What happens during upgrade:**
- ✅ Preserves your existing `/etc/duckdns.conf`
- ✅ Updates script and service files
- ✅ Adds new config options (like `ENABLE_IPV6`)
- ✅ Automatically restarts service if it was running
- ✅ Shows service status after restart

### Manual Setup
```bash
# 1. Configure
sudo cp config/duckdns.conf.example /etc/duckdns.conf
sudo nano /etc/duckdns.conf  # Edit domain/token
sudo chmod 600 /etc/duckdns.conf

# 2. Install script
sudo cp bin/duck.sh /usr/local/bin/duckdns-update.sh
sudo chmod +x /usr/local/bin/duckdns-update.sh

# 3. Setup systemd (edit User/Group if not ubuntu/ec2-user)
sudo cp systemd/duckdns.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start duckdns
sudo systemctl enable duckdns
```

## Configuration

### `/etc/duckdns.conf`
```bash
DUCKDNS_DOMAIN=mydomain          # Without .duckdns.org
DUCKDNS_TOKEN=your-token-here    # From duckdns.org
CHECK_INTERVAL=300               # Seconds (default: 5min)
LOG_FILE=/var/log/duckdns.log    # Log location
ENABLE_IPV6=true                 # Enable IPv6 support (default: true)
```

### IPv6 Support
- **Automatic detection**: The script checks if your EC2 instance has an IPv6 address
- **Dual-stack updates**: Updates both IPv4 and IPv6 addresses when available
- **Graceful fallback**: Works with IPv4-only instances (IPv6 update is skipped if not available)
- **Disable IPv6**: Set `ENABLE_IPV6=false` in config to disable IPv6 completely

**Note**: To enable IPv6 on your EC2 instance, assign an IPv6 address to your instance in the VPC settings.

### Platform Support
- **Ubuntu 24.04 LTS**: Uses `ubuntu` user (auto-detected)
- **Amazon Linux 2023**: Uses `ec2-user` user (auto-detected)
- Installer automatically configures correct user and permissions

### Security Notes
- Config file has `600` permissions (owner read/write only)
- Service runs as `ubuntu` user (change in [duckdns.service](../duckdns.service) if needed)
- Never commit `/etc/duckdns.conf` to git

## Operation

### Service Management
```bash
sudo systemctl start duckdns      # Start service
sudo systemctl stop duckdns       # Stop service
sudo systemctl restart duckdns    # Restart service
sudo systemctl status duckdns     # Check status
sudo systemctl enable duckdns     # Enable at boot
sudo systemctl disable duckdns    # Disable at boot
```

### Monitoring
```bash
# Live logs (systemd journal - timestamps added by journald)
sudo journalctl -u duckdns -f

# Log file (with ISO 8601 timestamps from script)
sudo tail -f /var/log/duckdns.log

# Check if service is running
systemctl is-active duckdns
```

**Note on timestamps**: journalctl output includes timestamps from systemd, while `/var/log/duckdns.log` has timestamps added by the script. Both log the same events, but journalctl provides additional metadata (process ID, hostname).

**Health check logs**: The service logs "Still monitoring - IP unchanged" every hour (12 checks × 5min interval) to confirm it's running properly when no IP changes occur.

### Log Rotation
Configured via `/etc/logrotate.d/duckdns`:
- Daily rotation
- Keep 7 days
- Compress old logs

## Troubleshooting

### Service Won't Start
```bash
# Check detailed error
sudo journalctl -u duckdns -n 50 --no-pager

# Verify config exists
ls -la /etc/duckdns.conf

# Test script manually
sudo -u ubuntu CONFIG_FILE=/etc/duckdns.conf /usr/local/bin/duckdns-update.sh
```

### IMDSv2 Not Working
```bash
# Test IMDSv2 token retrieval
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
echo $TOKEN

# Get public IP with token
curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4
```

### API Returns "KO"
- Verify domain exists at https://www.duckdns.org
- Check token is correct in `/etc/duckdns.conf`
- Ensure domain matches exactly (without `.duckdns.org`)

### High CPU Usage
- Check `CHECK_INTERVAL` isn't too low (minimum recommended: 60s)
- Ensure no multiple instances running: `ps aux | grep duckdns-update`

## AWS Requirements
- EC2 instance with IMDSv2 enabled (default on new instances)
- Public IPv4 address assigned
- **Optional**: IPv6 address assigned (for dual-stack DNS records)
- Outbound HTTPS (443) access to `www.duckdns.org`
- No special IAM permissions needed (uses metadata service)

### Enabling IPv6 on EC2
To use IPv6 support, your EC2 instance needs an IPv6 address:
1. Ensure your VPC has an IPv6 CIDR block assigned
2. Assign an IPv6 CIDR to your subnet
3. Assign an IPv6 address to your EC2 instance
4. Update route tables and security groups to allow IPv6 traffic

## Common Modifications

### Change Check Interval
Edit `/etc/duckdns.conf`:
```bash
CHECK_INTERVAL=60  # Check every minute
```

### Run as Different User
Edit [duckdns.service](../duckdns.service):
```ini
User=your-user
Group=your-group
```
Then: `sudo systemctl daemon-reload && sudo systemctl restart duckdns`

### Multiple Domains
DuckDNS supports comma-separated domains. Edit `/etc/duckdns.conf`:
```bash
DUCKDNS_DOMAIN=domain1,domain2,domain3
```

### Custom Log Location
Edit `/etc/duckdns.conf` and ensure service has write access:
```bash
LOG_FILE=/custom/path/duckdns.log
```

## Migration from Cron-Based Scripts

If you're currently using the cron approach from DuckDNS official docs:

```bash
# 1. Remove old cron job
crontab -e
# Delete the line: */5 * * * * /path/to/duck.sh >/dev/null 2>&1

# 2. Run installer
sudo ./install.sh
sudo nano /etc/duckdns.conf  # Configure your domain and token

# 3. Start and enable service
sudo systemctl start duckdns
sudo systemctl enable duckdns

# 4. Verify it's running
sudo systemctl status duckdns
```

**Benefits of switching:**
- ✅ No more 5-minute DNS downtime after EC2 restarts
- ✅ Automatic service recovery on failures
- ✅ Better logging and monitoring via journalctl
- ✅ Proper process management (no orphaned processes)

## Development

### Test Script Changes
```bash
# Test with custom config
CONFIG_FILE=./duckdns.conf bin/duck.sh

# Dry-run single update (ctrl+c after first check)
sudo -u ubuntu CONFIG_FILE=/etc/duckdns.conf /usr/local/bin/duckdns-update.sh
```

### Debug Mode
Add to top of [bin/duck.sh](bin/duck.sh):
```bash
set -x  # Print all commands
```

## References
- Original DuckDNS EC2 docs: https://www.duckdns.org/install.jsp#ec2
- AWS IMDSv2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- systemd service hardening: `man systemd.exec`
