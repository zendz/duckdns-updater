#!/bin/bash
set -euo pipefail

# Load configuration
CONFIG_FILE="${CONFIG_FILE:-/etc/duckdns.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Validate required variables
: "${DUCKDNS_DOMAIN:?ERROR: DUCKDNS_DOMAIN not set in config}"
: "${DUCKDNS_TOKEN:?ERROR: DUCKDNS_TOKEN not set in config}"
: "${CHECK_INTERVAL:=300}"
: "${LOG_FILE:=/var/log/duckdns.log}"

# Initialize
current_ip=""
retry_count=0
max_retries=3
check_count=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

# Get EC2 public IP using IMDSv2 (token-based authentication)
get_ec2_ip() {
    local token
    local ip
    
    # Get IMDSv2 token (valid for 21600 seconds = 6 hours)
    token=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
    
    if [[ -z "$token" ]]; then
        log_error "Failed to get IMDSv2 token"
        return 1
    fi
    
    # Get public IPv4 using the token
    ip=$(curl -sf -H "X-aws-ec2-metadata-token: $token" \
        http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
    
    if [[ -z "$ip" ]]; then
        log_error "Failed to get public IP from EC2 metadata"
        return 1
    fi
    
    echo "$ip"
}

# Update DuckDNS with retry logic
update_duckdns() {
    local ip="$1"
    local response
    local attempt=0
    
    while [[ $attempt -lt $max_retries ]]; do
        response=$(curl -sf "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${ip}" 2>/dev/null)
        
        if [[ "$response" == "OK" ]]; then
            log "Successfully updated DuckDNS: ${DUCKDNS_DOMAIN}.duckdns.org -> $ip"
            return 0
        elif [[ "$response" == "KO" ]]; then
            log_error "DuckDNS API returned error (KO) - check domain and token"
            return 1
        else
            attempt=$((attempt + 1))
            if [[ $attempt -lt $max_retries ]]; then
                log_error "DuckDNS update failed (attempt $attempt/$max_retries), retrying in 10s..."
                sleep 10
            fi
        fi
    done
    
    log_error "Failed to update DuckDNS after $max_retries attempts"
    return 1
}

log "DuckDNS updater started for ${DUCKDNS_DOMAIN}.duckdns.org (check interval: ${CHECK_INTERVAL}s)"

# Main loop
while true; do
    latest_ip=$(get_ec2_ip)
    
    if [[ -z "$latest_ip" ]]; then
        retry_count=$((retry_count + 1))
        sleep_time=$((CHECK_INTERVAL * retry_count))
        log_error "Failed to get IP (retry $retry_count), sleeping ${sleep_time}s"
        sleep "$sleep_time"
        
        # Reset retry count if it gets too high
        if [[ $retry_count -gt 5 ]]; then
            retry_count=5
        fi
        continue
    fi
    
    # Reset retry count on successful IP fetch
    retry_count=0
    
    if [[ "$current_ip" != "$latest_ip" ]]; then
        log "IP changed: $current_ip -> $latest_ip"
        if update_duckdns "$latest_ip"; then
            current_ip="$latest_ip"
        fi
    else
        # Log every 12 checks (1 hour) to show it's still running
        check_count=$((check_count + 1))
        if [[ $((check_count % 12)) -eq 0 ]]; then
            log "Still monitoring - IP unchanged: $current_ip (${check_count} checks)"
        fi
    fi
    
    sleep "$CHECK_INTERVAL"
done
