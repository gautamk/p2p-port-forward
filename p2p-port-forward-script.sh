#!/bin/bash

# ============================================================================
# P2P Port Forward Script for unRAID + Wireguard VPN
# ============================================================================
#
# DESCRIPTION:
#   Automatically manages NAT-PMP port forwarding for torrent clients running
#   in Docker containers on unRAID, tunneled through Wireguard VPN.
#   Solves the dynamic port problem with commercial VPNs.
#
# ============================================================================
# unRAID USERSCRIPTS PLUGIN SETUP INSTRUCTIONS
# ============================================================================
#
# STEP 1: Install User Scripts Plugin
#   1. Go to unRAID WebGUI → Apps tab
#   2. Search for "User Scripts"
#   3. Click "Install" on the plugin by Squid
#   4. Wait for installation to complete
#
# STEP 2: Create New Script
#   1. Go to Settings → User Scripts
#   2. Click "Add New Script" button at bottom
#   3. Name it: "P2P Port Forward"
#   4. Click on the gear icon next to the script name
#   5. Click "Edit Script"
#   6. Delete the default content
#   7. Paste this entire script
#   8. Click "Save Changes"
#
# STEP 3: Configure Variables (REQUIRED)
#   Edit the CONFIGURATION section below to match your setup:
#   - CONTAINER: Your torrent container name (e.g., "qbittorrent")
#   - LISTENING_PORT: Port your torrent client listens on (e.g., 6881)
#   - WGTUNNEL: Your Wireguard gateway IP (found in VPN Manager)
#     * Go to Settings → VPN Manager
#     * Look for "Local tunnel network pool" (e.g., 10.2.0.0/24)
#     * Change the last number from .0 to .1 (e.g., 10.2.0.1)
#
# STEP 4: Set Schedule (RECOMMENDED)
#   1. Click the gear icon next to your script
#   2. Click "Schedule Disabled"
#   3. Choose one of these options:
#
#   OPTION A - Run Every 15 Minutes (Recommended for 24/7 operation)
#     * Select "Custom"
#     * Enter: */15 * * * *
#     * This ensures port mapping never expires (20 min lease, 15 min renewal)
#
#   OPTION B - Run at Array Startup (For manual array starts)
#     * Select "At Startup of Array"
#     * Set MAX_RENEWALS=240 (in config below) for ~3 hour runtime
#     * Good if you start/stop array regularly
#
#   OPTION C - Manual Only (For testing)
#     * Leave as "Schedule Disabled"
#     * Run manually by clicking "Run Script" button
#
# STEP 5: Test the Script
#   1. Click "Run Script" button (not "Run in Background")
#   2. Watch the output in real-time
#   3. Verify you see "SUCCESS: VPN port XXXXX → 6881" messages
#   4. Check your torrent client shows the mapped port
#
# STEP 6: Verify in Torrent Client
#   For qBittorrent:
#     1. Go to Settings → Connection
#     2. The "Port used for incoming connections" should match
#        the mapped port shown in the script output
#     3. Click "Test Port" to verify it's accessible
#
# ============================================================================
# TROUBLESHOOTING
# ============================================================================
#
# PROBLEM: "Container 'qbittorrent' is not running"
#   SOLUTION: 
#     - Check container name is exact (case-sensitive)
#     - Run: docker ps
#     - Copy exact name from "NAMES" column
#
# PROBLEM: "Docker is not available"
#   SOLUTION:
#     - Wait for array to fully start
#     - Docker starts after array is online
#     - If using "At Startup", add sleep 60 to config
#
# PROBLEM: "Failed to map port"
#   SOLUTION:
#     - Verify WGTUNNEL IP is correct (.1, not .0)
#     - Check Wireguard VPN is connected
#     - Ensure VPN supports NAT-PMP (some don't)
#     - Run inside container: ping $WGTUNNEL
#
# PROBLEM: "natpmpc not found after installation"
#   SOLUTION:
#     - Container may not support apk (Alpine package manager)
#     - Check container OS: docker exec CONTAINER cat /etc/os-release
#     - You may need a different container image
#
# PROBLEM: Script runs but port keeps changing
#   SOLUTION:
#     - This is normal with dynamic VPNs
#     - Script will update torrent client automatically
#     - Run every 15 minutes to minimize port changes
#
# PROBLEM: "Permission denied" on log file
#   SOLUTION:
#     - Script will fallback to stdout (userscripts captures it)
#     - Or change LOGFILE to /tmp/natpmp_forward.log
#
# ============================================================================
# VIEW LOGS
# ============================================================================
#
# Real-time (while running):
#   - Click "Run Script" to see live output
#
# Historical logs:
#   - Go to Settings → User Scripts
#   - Click gear icon → "View Log"
#   - Or check: /var/log/natpmp_forward.log
#
# ============================================================================
# ADVANCED CONFIGURATION
# ============================================================================
#
# Environment Variable Override:
#   Instead of editing this script, you can set environment variables
#   in the userscripts plugin:
#
#   1. Click gear icon → "Edit Script"
#   2. Add at the top (before the script):
#      export CONTAINER="transmission"
#      export LISTENING_PORT="51413"
#
# Multiple Containers:
#   Create separate scripts for each container:
#   - "P2P Port Forward - qBittorrent"
#   - "P2P Port Forward - Transmission"
#   Each with different CONTAINER and LISTENING_PORT values
#
# Notification on Failure:
#   Add to unRAID notification system:
#   1. Install "Notifications" plugin
#   2. Add to end of script:
#      if [[ $SUCCESSFUL_RENEWALS -eq 0 ]]; then
#        /usr/local/emhttp/webGui/scripts/notify -s "Port Forward Failed" \
#          -d "P2P port forwarding failed for $CONTAINER"
#      fi
#
# ============================================================================

# ============================================================================
# CONFIGURATION
# ============================================================================
# Using ${VAR:-default} allows environment variables to override defaults
# Example: CONTAINER=transmission ./script.sh

CONTAINER="${CONTAINER:-qbittorrent}"           # Docker container name
LISTENING_PORT="${LISTENING_PORT:-6881}"        # Port your torrent client listens on
WGTUNNEL="${WGTUNNEL:-10.2.0.1}"                # Wireguard gateway IP (change last octet from .0 to .1)
LOGFILE="${LOGFILE:-/var/log/natpmp_forward.log}" # Log file path (in RAM to avoid USB wear)
LOG_RETENTION_DAY="${LOG_RETENTION_DAY:-3}"     # Days to keep logs before rotation

# How many renewal attempts to make (not an infinite loop)
# Each renewal runs natpmpc which sets a 1200 second (20 min) lease
# Default: 5 attempts = 5 renewals over ~2.5 minutes
# For "At Startup" schedule, set to 240 for ~3 hours of renewals
MAX_RENEWALS="${MAX_RENEWALS:-5}"

# Seconds between renewals (must be less than the 1200 second lease)
# Default: 30 seconds between each renewal attempt
# For "At Startup" schedule with MAX_RENEWALS=240, use 45 seconds
RENEWAL_INTERVAL="${RENEWAL_INTERVAL:-30}"

# ============================================================================
# SIGNAL HANDLING (Critical for userscripts plugin)
# ============================================================================
# When userscripts tries to stop the script, it sends SIGTERM
# We need to handle this gracefully to avoid orphaned processes

SCRIPT_RUNNING=true

# Trap handler for clean shutdown
# trap 'commands' SIGNALS means: when we receive these signals, run commands
cleanup() {
    echo "[$(date)] Received stop signal, cleaning up..."
    SCRIPT_RUNNING=false
    exit 0
}

# Register signal handlers
# SIGTERM: sent by userscripts "stop" button
# SIGINT: sent by Ctrl+C (if run manually)
trap cleanup SIGTERM SIGINT

# ============================================================================
# INPUT VALIDATION
# ============================================================================

# Container name: only allow alphanumeric, underscore, dash, and dot
# =~ is the regex match operator
# || { ... } means "if validation fails, do this"
[[ "$CONTAINER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { 
    echo "ERROR: Invalid container name. Only alphanumeric, underscore, dash, and dot allowed" 
    exit 1
}

# Port validation: must be number between 1-65535
# -a is logical AND operator in [[ ]] context
[[ "$LISTENING_PORT" =~ ^[0-9]+$ ]] && \
[[ "$LISTENING_PORT" -ge 1 ]] && \
[[ "$LISTENING_PORT" -le 65535 ]] || { 
    echo "ERROR: Port must be a number between 1-65535"
    exit 1
}

# IP address format validation: xxx.xxx.xxx.xxx
[[ "$WGTUNNEL" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { 
    echo "ERROR: Invalid IP address format"
    exit 1
}

# Renewal count validation
[[ "$MAX_RENEWALS" =~ ^[0-9]+$ ]] && [[ "$MAX_RENEWALS" -ge 1 ]] || {
    echo "ERROR: MAX_RENEWALS must be a positive number"
    exit 1
}

# Interval validation: reasonable range for renewals
[[ "$RENEWAL_INTERVAL" =~ ^[0-9]+$ ]] && \
[[ "$RENEWAL_INTERVAL" -ge 5 ]] && \
[[ "$RENEWAL_INTERVAL" -le 600 ]] || {
    echo "ERROR: RENEWAL_INTERVAL must be between 5-600 seconds"
    exit 1
}

# ============================================================================
# LOG FILE SETUP
# ============================================================================

# Create log directory if needed
# $(dirname "$LOGFILE") extracts directory from full path
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || {
    echo "WARNING: Could not create log directory, logging to stdout only"
    LOGFILE="/dev/null"
}

# Create log file with secure permissions (owner read/write only)
if [[ "$LOGFILE" != "/dev/null" ]]; then
    touch "$LOGFILE" 2>/dev/null && chmod 600 "$LOGFILE" 2>/dev/null || {
        echo "WARNING: Could not create/secure log file, logging to stdout only"
        LOGFILE="/dev/null"
    }
fi

# Logging helper function
# tee -a: append to both stdout and log file
log() {
    if [[ "$LOGFILE" != "/dev/null" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    fi
}

# ============================================================================
# LOG ROTATION
# ============================================================================

# Rotate log if older than retention period
# Only rotate if we have a real log file
if [[ -f "$LOGFILE" && "$LOGFILE" != "/dev/null" ]]; then
    # Calculate file age in days
    # date +%s = current timestamp
    # stat -c %Y = file modification timestamp
    # 86400 = seconds in a day
    # $(( ... )) performs arithmetic evaluation
    FILE_AGE_DAYS=$(( ($(date +%s) - $(stat -c %Y "$LOGFILE" 2>/dev/null || echo 0)) / 86400 ))
    
    if (( FILE_AGE_DAYS >= LOG_RETENTION_DAY )); then
        log "Rotating log file (age: $FILE_AGE_DAYS days)"
        # Move old log instead of deleting (safer)
        mv "$LOGFILE" "${LOGFILE}.old" 2>/dev/null
        touch "$LOGFILE" && chmod 600 "$LOGFILE"
    fi
fi

# ============================================================================
# DOCKER AVAILABILITY CHECK
# ============================================================================

log "Checking Docker availability..."

# During array start/stop, Docker may not be available
# Give it time to start (important for "At Startup of Array" schedule)
for i in {1..30}; do
    if docker info &>/dev/null; then
        log "Docker is available"
        break
    fi
    if [[ $i -eq 30 ]]; then
        log "ERROR: Docker is not available after 30 seconds"
        exit 1
    fi
    sleep 1
done

# ============================================================================
# CONTAINER STATUS CHECK
# ============================================================================

log "Checking container '$CONTAINER' status..."

# Check if container exists and is running
# timeout prevents hanging if Docker is unresponsive
# 2>&1 captures both stdout and stderr
if ! timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>&1 | grep -q "^true$"; then
    log "ERROR: Container '$CONTAINER' is not running"
    log "Available containers:"
    docker ps --format "{{.Names}}" 2>/dev/null || log "Could not list containers"
    exit 1
fi

log "Container '$CONTAINER' is running"

# ============================================================================
# INSTALL natpmpc IF NEEDED
# ============================================================================

log "Checking for natpmpc..."

# which natpmpc: returns 0 if found, 1 if not found
# &>/dev/null: suppress all output
if ! timeout 30 docker exec "$CONTAINER" which natpmpc &>/dev/null; then
    log "natpmpc not found, installing..."
    
    # Run installation with error handling
    # Don't use set -e, handle errors explicitly
    if timeout 300 docker exec "$CONTAINER" sh -c 'apk update && apk add --no-cache libnatpmp' 2>&1 | tee -a "$LOGFILE"; then
        log "natpmpc installed successfully"
    else
        log "ERROR: Failed to install natpmpc"
        exit 1
    fi
    
    # Verify installation worked
    if ! timeout 30 docker exec "$CONTAINER" which natpmpc &>/dev/null; then
        log "ERROR: natpmpc not found after installation"
        exit 1
    fi
else
    log "natpmpc is already installed"
fi

# ============================================================================
# PORT FORWARDING RENEWALS
# ============================================================================

log "Starting port forwarding renewals (max: $MAX_RENEWALS)"

# Counter for successful renewals
SUCCESSFUL_RENEWALS=0

# Loop with a fixed number of iterations (not infinite)
# This allows the script to finish and be re-run by userscripts scheduler
for RENEWAL_COUNT in $(seq 1 $MAX_RENEWALS); do
    
    # Check if we received a stop signal
    if [[ "$SCRIPT_RUNNING" != "true" ]]; then
        log "Stop signal received, exiting renewal loop"
        break
    fi
    
    log "=== Renewal attempt $RENEWAL_COUNT of $MAX_RENEWALS ==="
    
    # Re-check container is still running
    # During renewals, container could be stopped
    if ! timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "^true$"; then
        log "WARNING: Container stopped during renewals, waiting..."
        sleep "$RENEWAL_INTERVAL"
        continue  # Skip to next iteration
    fi
    
    # Renewal success flag for this iteration
    RENEWAL_SUCCESS=true
    
    # Map both TCP and UDP ports
    for PROTOCOL in tcp udp; do
        log "Mapping $PROTOCOL port..."
        
        # natpmpc parameters:
        # -a 0 = listen on all interfaces (0 = wildcard)
        # $LISTENING_PORT = internal port number
        # $PROTOCOL = tcp or udp
        # 1200 = lease duration in seconds (20 minutes)
        # -g $WGTUNNEL = gateway IP address
        # 2>&1 = redirect stderr to stdout for capture
        
        if OUTPUT=$(timeout 30 docker exec "$CONTAINER" natpmpc -a 0 "$LISTENING_PORT" "$PROTOCOL" 1200 -g "$WGTUNNEL" 2>&1); then
            # Success - log output
            echo "$OUTPUT" >> "$LOGFILE"
            
            # Extract mapped port number from output
            # grep -oP: Perl regex, -o = only matching part
            # \K = lookbehind (discard everything before)
            if MAPPED_PORT=$(echo "$OUTPUT" | grep -oP 'Mapped public port \K[0-9]+' | tail -n1); then
                if [[ -n "$MAPPED_PORT" ]]; then
                    log "SUCCESS: $PROTOCOL port $MAPPED_PORT → $LISTENING_PORT"
                fi
            fi
        else
            # Failed - log error but continue trying
            EXIT_CODE=$?
            log "WARNING: Failed to map $PROTOCOL port (exit code: $EXIT_CODE)"
            if [[ $EXIT_CODE -eq 124 ]]; then
                log "WARNING: Command timed out after 30 seconds"
            fi
            RENEWAL_SUCCESS=false
        fi
    done
    
    # Track successful complete renewals (both TCP and UDP succeeded)
    if [[ "$RENEWAL_SUCCESS" == "true" ]]; then
        ((SUCCESSFUL_RENEWALS++))
    fi
    
    # Wait before next renewal (unless this is the last one)
    if [[ $RENEWAL_COUNT -lt $MAX_RENEWALS ]]; then
        log "Waiting $RENEWAL_INTERVAL seconds before next renewal..."
        sleep "$RENEWAL_INTERVAL"
    fi
done

# ============================================================================
# COMPLETION SUMMARY
# ============================================================================

log "=== Script Complete ==="
log "Total renewals attempted: $MAX_RENEWALS"
log "Successful renewals: $SUCCESSFUL_RENEWALS"

# Exit with appropriate code
if [[ $SUCCESSFUL_RENEWALS -gt 0 ]]; then
    log "At least one renewal succeeded"
    exit 0
else
    log "ERROR: No successful renewals"
    exit 1
fi
