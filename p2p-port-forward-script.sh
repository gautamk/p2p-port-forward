#!/bin/bash

# Exit on error, exit on undefined variables, exit on pipe failures
# This prevents the script from continuing if any command fails unexpectedly
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================
# Using ${VAR:-default} syntax allows environment variables to override defaults
# Example: CONTAINER=transmission ./script.sh will use "transmission" instead

CONTAINER="${CONTAINER:-qbittorrent}"           # Docker container name
LISTENING_PORT="${LISTENING_PORT:-6881}"        # Port your torrent client listens on
WGTUNNEL="${WGTUNNEL:-10.2.0.1}"                # Wireguard gateway IP (change last octet from .0 to .1)
LOGFILE="${LOGFILE:-/var/log/natpmp_forward.log}" # Log file path (in RAM to avoid USB wear)
LOG_RETENTION_DAY="${LOG_RETENTION_DAY:-3}"     # Days to keep logs before rotation
INTERVAL="${INTERVAL:-45}"                       # Seconds between port mapping renewals

# ============================================================================
# INPUT VALIDATION (Security)
# ============================================================================
# These checks prevent command injection and invalid configurations

# Container name: only allow alphanumeric, underscore, dash, and dot
# The =~ operator tests if the string matches the regex pattern
# ^[a-zA-Z0-9_.-]+$ means: start(^), one or more allowed chars, end($)
[[ "$CONTAINER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { 
    echo "ERROR: Invalid container name. Only alphanumeric, underscore, dash, and dot allowed" 
    exit 1
}

# Port validation: must be a number between 1 and 65535
# -ge means "greater than or equal", -le means "less than or equal"
[[ "$LISTENING_PORT" =~ ^[0-9]+$ && "$LISTENING_PORT" -ge 1 && "$LISTENING_PORT" -le 65535 ]] || { 
    echo "ERROR: Port must be a number between 1-65535"
    exit 1
}

# IP address validation: must match IPv4 format (xxx.xxx.xxx.xxx)
# {1,3} means "1 to 3 digits"
[[ "$WGTUNNEL" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { 
    echo "ERROR: Invalid IP address format. Expected xxx.xxx.xxx.xxx"
    exit 1
}

# Interval validation: prevent DoS (too fast) or stale mappings (too slow)
[[ "$INTERVAL" -ge 10 && "$INTERVAL" -le 3600 ]] || { 
    echo "ERROR: Interval must be between 10-3600 seconds (10s to 1 hour)"
    exit 1
}

# ============================================================================
# LOG FILE SETUP
# ============================================================================

# Create log directory if it doesn't exist
# $(dirname "$LOGFILE") extracts the directory path from the full file path
# Example: /var/log/natpmp_forward.log → /var/log
mkdir -p "$(dirname "$LOGFILE")"

# Create log file and set secure permissions (read/write for owner only)
# chmod 600 means: owner can read+write (6), group nothing (0), others nothing (0)
touch "$LOGFILE" && chmod 600 "$LOGFILE"

# Helper function for timestamped logging
# $* means "all arguments passed to this function"
# tee -a appends to both stdout (console) and the log file
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# ============================================================================
# CONTAINER INITIALIZATION
# ============================================================================

# Wait for container to fully start after system boot
sleep 60

# Verify container is running before proceeding
# timeout 10: kill the command if it takes longer than 10 seconds
# docker inspect -f '{{.State.Running}}': returns "true" if container is running
# 2>/dev/null: suppress error messages
# || { ... } executes if the previous command fails
timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true || {
    log "ERROR: Container '$CONTAINER' is not running"
    exit 1
}

# ============================================================================
# INSTALL natpmpc (NAT-PMP client tool)
# ============================================================================

# Check if natpmpc is already installed in the container
# which natpmpc returns 0 (success) if found, non-zero if not found
# &>/dev/null redirects both stdout and stderr to nowhere (silent)
# ! negates the result, so we enter the if-block when natpmpc is NOT found
if ! timeout 30 docker exec "$CONTAINER" which natpmpc &>/dev/null; then
    log "Installing natpmpc in container '$CONTAINER'..."
    
    # Install natpmpc using Alpine Linux package manager (apk)
    # sh -c '...' runs multiple commands in a single docker exec session
    # && chains commands: second command only runs if first succeeds
    timeout 300 docker exec "$CONTAINER" sh -c 'apk update && apk add --no-cache libnatpmp' || {
        log "ERROR: Failed to install natpmpc"
        exit 1
    }
fi

# ============================================================================
# MAIN LOOP - Port Forwarding
# ============================================================================

while true; do
    
    # ========================================================================
    # LOG ROTATION
    # ========================================================================
    
    if [[ -f "$LOGFILE" ]]; then
        # Calculate log file age in days
        # date +%s: current time in seconds since epoch (Unix timestamp)
        # stat -c %Y: file modification time in seconds since epoch
        # Subtract and divide by 86400 (seconds in a day) to get age in days
        # $(( ... )) performs arithmetic evaluation
        FILE_AGE_DAYS=$(( ($(date +%s) - $(stat -c %Y "$LOGFILE" 2>/dev/null || echo 0)) / 86400 ))
        
        # (( ... )) is arithmetic comparison context
        # If file is older than retention period, delete and recreate it
        (( FILE_AGE_DAYS >= LOG_RETENTION_DAY )) && rm -f "$LOGFILE" && touch "$LOGFILE" && chmod 600 "$LOGFILE"
    fi

    # ========================================================================
    # CONTAINER STATUS CHECK
    # ========================================================================
    
    # Re-check container is still running (in case it crashed or was stopped)
    if ! timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        log "Container stopped, waiting..."
        sleep "$INTERVAL"
        continue  # Skip to next iteration of while loop
    fi

    # ========================================================================
    # PORT MAPPING (TCP and UDP)
    # ========================================================================
    
    # Loop through both protocols to avoid code duplication
    for PROTOCOL in tcp udp; do
        # natpmpc command breakdown:
        # -a 0: map all external IPs (0 = wildcard)
        # $LISTENING_PORT: the port number we want to forward
        # $PROTOCOL: tcp or udp
        # 1200: lease time in seconds (how long the mapping lasts)
        # -g $WGTUNNEL: gateway IP address
        # 2>&1: redirect stderr to stdout so we capture all output
        # $(...) captures the command output into the OUTPUT variable
        # || { ... } executes if natpmpc command fails
        OUTPUT=$(timeout 30 docker exec "$CONTAINER" natpmpc -a 0 "$LISTENING_PORT" "$PROTOCOL" 1200 -g "$WGTUNNEL" 2>&1) || {
            log "WARNING: Failed to map $PROTOCOL port"
            continue  # Skip to next protocol
        }
        # Append the full output to log file for debugging
        echo "$OUTPUT" >> "$LOGFILE"
    done

    # ========================================================================
    # EXTRACT MAPPED PORT NUMBER
    # ========================================================================
    
    # Run natpmpc again to get the current UDP mapping
    # grep -oP: -o shows only matching part, -P enables Perl regex
    # 'Mapped public port \K[0-9]+': 
    #   - Matches "Mapped public port " followed by digits
    #   - \K discards everything before it (lookbehind)
    #   - So only the port number is returned
    # tail -n1: take only the last line (most recent mapping)
    MAPPED_PORT=$(timeout 30 docker exec "$CONTAINER" natpmpc -a 0 "$LISTENING_PORT" udp 1200 -g "$WGTUNNEL" 2>&1 | grep -oP 'Mapped public port \K[0-9]+' | tail -n1)
    
    # Check if we successfully extracted a valid port number
    # -n tests if string is non-empty
    # [[ ... && ... ]] means both conditions must be true
    if [[ -n "$MAPPED_PORT" && "$MAPPED_PORT" =~ ^[0-9]+$ ]]; then
        log "SUCCESS: VPN port $MAPPED_PORT → $LISTENING_PORT"
    else
        log "WARNING: Could not determine mapped port"
    fi

    # ========================================================================
    # WAIT BEFORE NEXT RENEWAL
    # ========================================================================
    
    # Sleep for configured interval before renewing port mapping
    # Port mappings expire after 1200 seconds, so we renew every 45s by default
    sleep "$INTERVAL"
done
