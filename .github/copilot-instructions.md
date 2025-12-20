# DuckDNS Updater - AI Coding Agent Instructions

## Project Overview
Production-ready dynamic DNS updater for DuckDNS on AWS EC2. A **systemd-managed service** that monitors EC2 instance IP changes via IMDSv2 and updates DuckDNS records. Designed for Ubuntu 24.04 LTS and Amazon Linux 2023.

**Why systemd over cron?** The official DuckDNS docs suggest cron with 5-minute intervals. This causes **up to 5 minutes of DNS downtime** when EC2 restarts with a new IP. Our systemd service starts on boot and updates DNS within seconds, eliminating this critical window of unavailability.

## Architecture & Key Components

### Core Script: `bin/duck.sh`
- **IMDSv2 Token Flow**: Always use two-step authentication (PUT token request → GET with token header) when accessing EC2 metadata
- **Retry Pattern**: Exponential backoff with `$retry_count * $CHECK_INTERVAL` for IP fetch failures, fixed 10s retry for DuckDNS API calls
- **Response Validation**: DuckDNS API returns `OK` (success) or `KO` (error) as plain text - always check exact string match
- **Stateful Loop**: Tracks `current_ip` to avoid redundant API calls; only updates when IP actually changes

### Installation: `install.sh`
- **User Detection Logic**: Auto-detects `ubuntu` (Ubuntu) or `ec2-user` (Amazon Linux) using `id` command - never hardcode usernames
- **File Ownership Pattern**: Config file is 600 (owner-only), log file is 644 (world-readable), both owned by detected user
- **Sed Template Replacement**: Uses inline sed to replace `User=ec2-user` and `Group=ec2-user` in systemd unit before copying to `/etc/systemd/system/`

### Security Model
- **Configuration**: `/etc/duckdns.conf` has 600 permissions with `DUCKDNS_TOKEN` - never log or expose this value
- **Systemd Hardening**: Service runs as non-root (`ubuntu`/`ec2-user`) with `ProtectSystem=strict`, `ProtectHome=true`, only writes to `/var/log`
- **No IAM Needed**: Uses EC2 metadata service (link-local 169.254.169.254), no AWS credentials required

## Development Workflows

### Testing Changes to `bin/duck.sh`
```bash
# Test with custom config (avoid modifying /etc/duckdns.conf during dev)
CONFIG_FILE=./test-config.conf bin/duck.sh

# Single-run test as service user
sudo -u ubuntu CONFIG_FILE=/etc/duckdns.conf /usr/local/bin/duckdns-update.sh
# Ctrl+C after first IP check
```

### Debugging Service Issues
```bash
# View live logs (journald is primary log destination)
sudo journalctl -u duckdns -f

# Check last 50 lines on failure
sudo journalctl -u duckdns -n 50 --no-pager

# Test IMDSv2 manually (common failure point)
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4
```

### Installer Testing
```bash
# Installer must run as root
sudo ./install.sh
# Always verify: user detection, file permissions, systemd unit user/group
```

## Critical Conventions

### Bash Strict Mode
All scripts use `set -euo pipefail` - any unset variable or non-zero exit causes immediate failure. Use `${VAR:=default}` for optional vars.

### Logging Pattern
```bash
log "Message"          # Timestamp + stdout + append to LOG_FILE
log_error "Error msg"  # Timestamp + stderr + append to LOG_FILE
```

### Configuration Loading
Scripts source `/etc/duckdns.conf` via `source "$CONFIG_FILE"` with `# shellcheck source=/dev/null` comment to avoid linter warnings. Required vars validated with `: "${VAR:?ERROR: message}"` pattern.

### Platform Differences
- **Ubuntu**: Uses `ubuntu` user, `/home/ubuntu`
- **Amazon Linux**: Uses `ec2-user` user, `/home/ec2-user`
- Scripts/installer must handle both automatically via user detection, never assume one platform

## Integration Points

### DuckDNS API
- **URL**: `https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=${IP}`
- **Response**: Plain text `OK` or `KO` (no JSON)
- **Rate Limit**: No official limit, but use `CHECK_INTERVAL >= 60` to be safe

### EC2 Metadata Service (IMDSv2)
- **Token Endpoint**: `PUT http://169.254.169.254/latest/api/token` with header `X-aws-ec2-metadata-token-ttl-seconds: 21600`
- **Public IP**: `GET http://169.254.169.254/latest/meta-data/public-ipv4` with header `X-aws-ec2-metadata-token: $TOKEN`
- Token TTL is 6 hours (21600s) - always get fresh token per script invocation (systemd auto-restarts handle long-term)

### systemd Integration
- **Service Type**: `simple` (foreground process with infinite loop)
- **Restart Policy**: `always` with 10s delay - service self-heals on crashes
- **Logging**: `StandardOutput=journal` and `StandardError=journal` - all logs go to journald AND `/var/log/duckdns.log`

## Common Modifications

### Adding Features
- New config vars: Add to `config/duckdns.conf.example` with comments, validate in script with `: "${VAR:?ERROR}"`
- Error handling: Follow existing retry pattern (exponential for infra, fixed for API)
- Logging: Always use ISO 8601 timestamps via `$(date '+%Y-%m-%d %H:%M:%S')`

### Testing Checklist
1. Works on both Ubuntu and Amazon Linux (user detection, paths)
2. Handles IMDSv2 token failures gracefully (retry logic)
3. Config file missing or incomplete variables cause clear error messages
4. Service restarts cleanly via systemd (no zombie processes)
5. Log rotation doesn't break active logging
