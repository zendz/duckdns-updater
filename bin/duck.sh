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
: "${ENABLE_IPV6:=true}"

# Initialize
current_ipv4=""
current_ipv6=""
retry_count=0
max_retries=3
check_count=0

log() {
    # Print to stdout without timestamp (journald adds it)
    echo "$*"
    # Append to log file with timestamp
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log_error() {
    # Print to stderr without timestamp (journald adds it)
    echo "ERROR: $*" >&2
    # Append to log file with timestamp
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >> "$LOG_FILE"
}

# Get IMDSv2 token
get_imds_token() {
    local token
    token=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
    
    if [[ -z "$token" ]]; then
        log_error "Failed to get IMDSv2 token"
        return 1
    fi
    
    echo "$token"
}

# Get EC2 public IPv4 using IMDSv2
get_ec2_ipv4() {
    local token="$1"
    local ip
    
    ip=$(curl -sf -H "X-aws-ec2-metadata-token: $token" \
        http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
    
    if [[ -z "$ip" ]]; then
        return 1
    fi
    
    echo "$ip"
}

# Get EC2 public IPv6 using IMDSv2
get_ec2_ipv6() {
    local token="$1"
    local ipv6
    
    # Try to get IPv6 - it may not be available on all instances
    ipv6=$(curl -sf -H "X-aws-ec2-metadata-token: $token" \
        http://169.254.169.254/latest/meta-data/ipv6 2>/dev/null)
    
    # Return the IPv6 address (empty if not available)
    echo "$ipv6"
}

# Update DuckDNS with retry logic
update_duckdns() {
    local ipv4="$1"
    local ipv6="$2"
    local response
    local attempt=0
    local url="https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}"
    local ip_info=""
    
    # Build URL with available IPs
    if [[ -n "$ipv4" ]]; then
        url="${url}&ip=${ipv4}"
        ip_info="IPv4: $ipv4"
    fi
    
    if [[ -n "$ipv6" ]]; then
        url="${url}&ipv6=${ipv6}"
        if [[ -n "$ip_info" ]]; then
            ip_info="${ip_info}, IPv6: $ipv6"
        else
            ip_info="IPv6: $ipv6"
        fi
    fi
    
    while [[ $attempt -lt $max_retries ]]; do
        response=$(curl -sf "$url" 2>/dev/null)
        
        if [[ "$response" == "OK" ]]; then
            log "Successfully updated DuckDNS: ${DUCKDNS_DOMAIN}.duckdns.org -> $ip_info"
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

if [[ "$ENABLE_IPV6" == "true" ]]; then
    log "DuckDNS updater started for ${DUCKDNS_DOMAIN}.duckdns.org (IPv4 + IPv6, check interval: ${CHECK_INTERVAL}s)"
else
    log "DuckDNS updater started for ${DUCKDNS_DOMAIN}.duckdns.org (IPv4 only, check interval: ${CHECK_INTERVAL}s)"
fi

# Main loop
while true; do
    # Get IMDSv2 token
    token=$(get_imds_token)
    
    if [[ -z "$token" ]]; then
        retry_count=$((retry_count + 1))
        sleep_time=$((CHECK_INTERVAL * retry_count))
        log_error "Failed to get IMDSv2 token (retry $retry_count), sleeping ${sleep_time}s"
        sleep "$sleep_time"
        
        # Reset retry count if it gets too high
        if [[ $retry_count -gt 5 ]]; then
            retry_count=5
        fi
        continue
    fi
    
    # Get IPv4 address
    latest_ipv4=$(get_ec2_ipv4 "$token")
    
    if [[ -z "$latest_ipv4" ]]; then
        retry_count=$((retry_count + 1))
        sleep_time=$((CHECK_INTERVAL * retry_count))
        log_error "Failed to get IPv4 address (retry $retry_count), sleeping ${sleep_time}s"
        sleep "$sleep_time"
        
        # Reset retry count if it gets too high
        if [[ $retry_count -gt 5 ]]; then
            retry_count=5
        fi
        continue
    fi
    
    # Get IPv6 address if enabled
    latest_ipv6=""
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        latest_ipv6=$(get_ec2_ipv6 "$token")
    fi
    
    # Reset retry count on successful IP fetch
    retry_count=0
    
    # Check if either IP changed
    if [[ "$current_ipv4" != "$latest_ipv4" ]] || [[ "$current_ipv6" != "$latest_ipv6" ]]; then
        if [[ "$current_ipv4" != "$latest_ipv4" ]]; then
            log "IPv4 changed: $current_ipv4 -> $latest_ipv4"
        fi
        if [[ "$current_ipv6" != "$latest_ipv6" ]]; then
            if [[ -n "$latest_ipv6" ]]; then
                log "IPv6 changed: $current_ipv6 -> $latest_ipv6"
            elif [[ -n "$current_ipv6" ]]; then
                log "IPv6 removed (was: $current_ipv6)"
            fi
        fi
        
        if update_duckdns "$latest_ipv4" "$latest_ipv6"; then
            current_ipv4="$latest_ipv4"
            current_ipv6="$latest_ipv6"
        fi
    else
        # Log every 12 checks (1 hour) to show it's still running
        check_count=$((check_count + 1))
        if [[ $((check_count % 12)) -eq 0 ]]; then
            if [[ -n "$current_ipv6" ]]; then
                log "Still monitoring - IPs unchanged: IPv4=$current_ipv4, IPv6=$current_ipv6 (${check_count} checks)"
            else
                log "Still monitoring - IP unchanged: IPv4=$current_ipv4 (${check_count} checks)"
            fi
        fi
    fi
    
    sleep "$CHECK_INTERVAL"
done
