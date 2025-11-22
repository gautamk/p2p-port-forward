#!/bin/bash

# CONFIGURATION
CONTAINER="qbittorrent" # exact name of your torrent container in unRAID
LISTENING_PORT="6881" # port that your torrent client is expecting to listen on for p2p connections
WGTUNNEL="10.2.0.1" # wireguard local tunnel network pool, found in unRAID VPN manager. Copy this address and change the final octet to 1 instead of 0.
LOGFILE="/var/log/natpmp_forward.log" # /var/log will log to RAM, which is ideal. Avoid logging to the USB flash drive.
LOG_RETENTION_DAY=3 # recommend 1-3 days so the log file does not grow endlessly
INTERVAL=45 # script loop frequency, in seconds

# ============================================================================
# SECURITY VALIDATION FUNCTIONS
# ============================================================================

# Validate port number is in valid range
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Port must be a number" >&2
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        echo "ERROR: Port must be between 1 and 65535" >&2
        return 1
    fi
    return 0
}

# Validate IP address format
validate_ip() {
    local ip="$1"
    if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERROR: Invalid IP address format" >&2
        return 1
    fi
    # Validate each octet is <= 255
    IFS='.' read -ra OCTETS <<< "$ip"
    for octet in "${OCTETS[@]}"; do
        if (( octet > 255 )); then
            echo "ERROR: IP address octet out of range" >&2
            return 1
        fi
    done
    return 0
}

# Validate container name - allow only safe characters
validate_container_name() {
    local name="$1"
    if ! [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "ERROR: Invalid container name. Only alphanumeric, underscore, dash, and dot allowed" >&2
        return 1
    fi
    if [[ ${#name} -gt 255 ]]; then
        echo "ERROR: Container name too long" >&2
        return 1
    fi
    return 0
}

# Validate interval is within reasonable bounds
validate_interval() {
    local interval="$1"
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Interval must be a positive number" >&2
        return 1
    fi
    if (( interval < 10 )); then
        echo "ERROR: Interval must be at least 10 seconds to prevent DoS" >&2
        return 1
    fi
    if (( interval > 3600 )); then
        echo "ERROR: Interval must be less than 3600 seconds (1 hour)" >&2
        return 1
    fi
    return 0
}

# Validate and secure log file path
validate_logfile() {
    local logfile="$1"
    
    # Prevent path traversal
    if [[ "$logfile" =~ \.\. ]]; then
        echo "ERROR: Log file path cannot contain '..' (path traversal attempt)" >&2
        return 1
    fi
    
    # Must be absolute path
    if [[ ! "$logfile" =~ ^/ ]]; then
        echo "ERROR: Log file must be an absolute path" >&2
        return 1
    fi
    
    # Restrict to safe directories
    if [[ ! "$logfile" =~ ^/(var/log|tmp|mnt/user/appdata) ]]; then
        echo "WARNING: Log file should be in /var/log, /tmp, or /mnt/user/appdata" >&2
    fi
    
    return 0
}

# Set secure permissions on log file
secure_logfile() {
    local logfile="$1"
    if [[ -f "$logfile" ]]; then
        chmod 600 "$logfile" 2>/dev/null || {
            echo "WARNING: Could not set secure permissions on log file" >&2
        }
    fi
}

# ============================================================================
# VALIDATE ALL CONFIGURATION PARAMETERS
# ============================================================================

echo "Validating configuration..."

validate_container_name "$CONTAINER" || exit 1
validate_port "$LISTENING_PORT" || exit 1
validate_ip "$WGTUNNEL" || exit 1
validate_logfile "$LOGFILE" || exit 1
validate_interval "$INTERVAL" || exit 1

echo "Configuration validated successfully."

# ============================================================================
# MAIN SCRIPT
# ============================================================================

# Create log directory and file with secure permissions
LOGDIR="$(dirname "$LOGFILE")"
if [[ ! -d "$LOGDIR" ]]; then
    mkdir -p "$LOGDIR" || {
        echo "ERROR: Could not create log directory: $LOGDIR" >&2
        exit 1
    }
fi

# Create log file with secure permissions
touch "$LOGFILE" 2>/dev/null || {
    echo "ERROR: Could not create log file: $LOGFILE" >&2
    exit 1
}
secure_logfile "$LOGFILE"

# Wait for container to initialize
sleep 60

# Check if container is running before starting
if ! timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    echo "Container '$CONTAINER' is NOT running. Exiting." | tee -a "$LOGFILE"
    exit 1
fi

# Check/install libnatpmp once before loop
if ! timeout 30 docker exec "$CONTAINER" which natpmpc &>/dev/null; then
    echo "natpmpc not found, installing in container '$CONTAINER'..." | tee -a "$LOGFILE"
    
    # Attempt installation with timeout
    if ! timeout 300 docker exec "$CONTAINER" apk update; then
        echo "ERROR: Failed to update package repository in container" | tee -a "$LOGFILE"
        exit 1
    fi
    
    if ! timeout 300 docker exec "$CONTAINER" apk add --no-cache libnatpmp; then
        echo "ERROR: Failed to install libnatpmp in container" | tee -a "$LOGFILE"
        exit 1
    fi
    
    # Verify installation succeeded
    if ! timeout 30 docker exec "$CONTAINER" which natpmpc &>/dev/null; then
        echo "ERROR: natpmpc installation verification failed" | tee -a "$LOGFILE"
        exit 1
    fi
    
    echo "natpmpc installed successfully" | tee -a "$LOGFILE"
fi

while true; do

    # Rotate log if older than retention period
    if [[ -f "$LOGFILE" ]]; then
        FILE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$LOGFILE" 2>/dev/null || echo 0) ) / 86400 ))
        if (( FILE_AGE_DAYS >= LOG_RETENTION_DAY )); then
            # Validate before deletion
            if [[ -f "$LOGFILE" && ! -L "$LOGFILE" ]]; then
                rm -f "$LOGFILE"
                touch "$LOGFILE"
                secure_logfile "$LOGFILE"
            fi
        fi
    fi

    # Ensure log file still has secure permissions
    secure_logfile "$LOGFILE"

    DATE_LINE="===== $(date) ====="
    echo "$DATE_LINE"
    echo "$DATE_LINE" >> "$LOGFILE"

    # Check that container is still running in each loop
    if ! timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        echo "Container '$CONTAINER' is NOT running." | tee -a "$LOGFILE"
        sleep "$INTERVAL"
        continue
    fi

    # Run natpmpc for TCP with timeout
    TCP_OUTPUT=$(timeout 30 docker exec "$CONTAINER" natpmpc -a 0 "$LISTENING_PORT" tcp 1200 -g "$WGTUNNEL" 2>&1)
    TCP_EXIT=$?
    echo "TCP Mapping Output:" >> "$LOGFILE"
    echo "$TCP_OUTPUT" >> "$LOGFILE"
    if [[ $TCP_EXIT -eq 124 ]]; then
        echo "WARNING: TCP mapping command timed out" >> "$LOGFILE"
    fi
    echo "" >> "$LOGFILE"

    # Run natpmpc for UDP with timeout
    UDP_OUTPUT=$(timeout 30 docker exec "$CONTAINER" natpmpc -a 0 "$LISTENING_PORT" udp 1200 -g "$WGTUNNEL" 2>&1)
    UDP_EXIT=$?
    echo "UDP Mapping Output:" >> "$LOGFILE"
    echo "$UDP_OUTPUT" >> "$LOGFILE"
    if [[ $UDP_EXIT -eq 124 ]]; then
        echo "WARNING: UDP mapping command timed out" >> "$LOGFILE"
    fi
    echo "" >> "$LOGFILE"

    # Extract mapped port
    MAPPED_PORT=$(echo "$UDP_OUTPUT" | grep -oP 'Mapped public port \K[0-9]+' | tail -n1)

    if [[ -z "$MAPPED_PORT" || ! "$MAPPED_PORT" =~ ^[0-9]+$ ]]; then
        echo "Failed to map port or retrieve mapped port. Check natpmpc output above." | tee -a "$LOGFILE"
        echo "" >> "$LOGFILE"
    else
        echo "VPN port mapped successfully: $MAPPED_PORT to $LISTENING_PORT" | tee -a "$LOGFILE"
        echo "" >> "$LOGFILE"
    fi

    sleep "$INTERVAL"
done
