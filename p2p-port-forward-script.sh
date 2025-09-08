#!/bin/bash

# CONFIGURATION
CONTAINER="qbittorrent" # exact name of your torrent container in unRAID
LISTENING_PORT="6881" # port that your torrent client is expecting to listen on for p2p connections
WGTUNNEL="10.2.0.1" # wireguard local tunnel network pool, found in unRAID VPN manager. Copy this address and change the final octet to 1 instead of 0.
LOGFILE="/var/log/natpmp_forward.log" # /var/log will log to RAM, which is ideal. Avoid logging to the USB flash drive.
LOG_RETENTION_DAY=3 # recommend 1-3 days so the log file does not grow endlessly
INTERVAL=45 # script loop frequency, in seconds

# Create log directory and file
mkdir -p "$(dirname "$LOGFILE")"

# Function to run diagnostics
run_diagnostics() {
    echo "=== DIAGNOSTIC INFORMATION ===" >> "$LOGFILE"
    
    # Check container network configuration
    echo "Container network info:" >> "$LOGFILE"
    docker exec "$CONTAINER" ip addr show 2>/dev/null >> "$LOGFILE" || echo "Failed to get container IP info" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
    
    # Test connectivity to WireGuard gateway
    echo "Testing connectivity to WireGuard gateway ($WGTUNNEL):" >> "$LOGFILE"
    if docker exec "$CONTAINER" ping -c 3 "$WGTUNNEL" 2>&1 >> "$LOGFILE"; then
        echo "✓ WireGuard gateway is reachable" >> "$LOGFILE"
    else
        echo "✗ WireGuard gateway is NOT reachable" >> "$LOGFILE"
    fi
    echo "" >> "$LOGFILE"
    
    # Test external connectivity
    echo "Testing external connectivity:" >> "$LOGFILE"
    if docker exec "$CONTAINER" nslookup google.com 2>&1 >> "$LOGFILE"; then
        echo "✓ External DNS resolution works" >> "$LOGFILE"
    else
        echo "✗ External DNS resolution failed" >> "$LOGFILE"
    fi
    echo "" >> "$LOGFILE"
    
    # Check if qBittorrent is listening on the configured port
    echo "Checking if qBittorrent is listening on port $LISTENING_PORT:" >> "$LOGFILE"
    if docker exec "$CONTAINER" netstat -ln 2>/dev/null | grep ":$LISTENING_PORT " >> "$LOGFILE"; then
        echo "✓ qBittorrent is listening on port $LISTENING_PORT" >> "$LOGFILE"
    else
        echo "✗ qBittorrent is NOT listening on port $LISTENING_PORT" >> "$LOGFILE"
        echo "Available listening ports in container:" >> "$LOGFILE"
        docker exec "$CONTAINER" netstat -ln 2>/dev/null | grep LISTEN >> "$LOGFILE" || echo "netstat not available" >> "$LOGFILE"
    fi
    echo "" >> "$LOGFILE"
    
    echo "=== END DIAGNOSTICS ===" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
}

# Wait for container to initialize
sleep 60

# Check if container is running before starting
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    echo "Container '$CONTAINER' is NOT running. Exiting." | tee -a "$LOGFILE"
    exit 1
fi

# Function to ensure libnatpmp is installed
ensure_libnatpmp_installed() {
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if docker exec "$CONTAINER" which natpmpc &>/dev/null; then
            echo "natpmpc is available in container '$CONTAINER'" | tee -a "$LOGFILE"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        echo "natpmpc not found, installing in container '$CONTAINER' (attempt $retry_count/$max_retries)..." | tee -a "$LOGFILE"
        
        if docker exec "$CONTAINER" apk update && docker exec "$CONTAINER" apk add --no-cache libnatpmp; then
            echo "Successfully installed libnatpmp in container '$CONTAINER'" | tee -a "$LOGFILE"
            return 0
        else
            echo "Failed to install libnatpmp (attempt $retry_count/$max_retries)" | tee -a "$LOGFILE"
            if [ $retry_count -lt $max_retries ]; then
                echo "Retrying in 10 seconds..." | tee -a "$LOGFILE"
                sleep 10
            fi
        fi
    done
    
    echo "ERROR: Failed to install libnatpmp after $max_retries attempts" | tee -a "$LOGFILE"
    return 1
}

# Initial libnatpmp installation check
if ! ensure_libnatpmp_installed; then
    echo "Cannot proceed without libnatpmp. Exiting." | tee -a "$LOGFILE"
    exit 1
fi

while true; do

    # Rotate log if older than retention period
    if [[ -f "$LOGFILE" ]]; then
        FILE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$LOGFILE") ) / 86400 ))
        if (( FILE_AGE_DAYS >= LOG_RETENTION_DAY )); then
            rm -f "$LOGFILE"
        fi
    fi

    DATE_LINE="===== $(date) ====="
    echo "$DATE_LINE"
    echo "$DATE_LINE" >> "$LOGFILE"

    # Check that container is still running in each loop
    if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        echo "Container '$CONTAINER' is NOT running." | tee -a "$LOGFILE"
        sleep "$INTERVAL"
        continue
    fi

    # Ensure libnatpmp is still installed (in case container was restarted)
    if ! docker exec "$CONTAINER" which natpmpc &>/dev/null; then
        echo "natpmpc no longer available, reinstalling..." | tee -a "$LOGFILE"
        if ! ensure_libnatpmp_installed; then
            echo "Failed to reinstall libnatpmp, skipping this cycle" | tee -a "$LOGFILE"
            sleep "$INTERVAL"
            continue
        fi
    fi

    # Run diagnostics every few cycles (every 10 minutes with default 45s interval)
    CYCLE_COUNT=${CYCLE_COUNT:-0}
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    if (( CYCLE_COUNT % 15 == 1 )); then  # Run diagnostics every 15 cycles
        run_diagnostics
    fi

    # Function to run natpmpc with retry logic
    run_natpmpc_with_retry() {
        local protocol=$1
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            echo "Running natpmpc for $protocol (attempt $((retry_count + 1))/$max_retries)..." >> "$LOGFILE"
            
            local output
            output=$(docker exec "$CONTAINER" natpmpc -a 0 "$LISTENING_PORT" "$protocol" 1200 -g "$WGTUNNEL" 2>&1)
            local exit_code=$?
            
            echo "$protocol Mapping Output:" >> "$LOGFILE"
            echo "$output" >> "$LOGFILE"
            echo "" >> "$LOGFILE"
            
            # Check for common error patterns
            if echo "$output" | grep -q "sendto.*: Network is unreachable"; then
                echo "Network unreachable error detected for $protocol" >> "$LOGFILE"
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    echo "Retrying in 5 seconds..." >> "$LOGFILE"
                    sleep 5
                    continue
                fi
            elif echo "$output" | grep -q "Mapped public port"; then
                echo "Successfully mapped $protocol port" >> "$LOGFILE"
                echo "$output"
                return 0
            elif [ $exit_code -ne 0 ]; then
                echo "natpmpc failed with exit code $exit_code for $protocol" >> "$LOGFILE"
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    echo "Retrying in 5 seconds..." >> "$LOGFILE"
                    sleep 5
                    continue
                fi
            else
                echo "$output"
                return 0
            fi
        done
        
        echo "Failed to map $protocol port after $max_retries attempts" >> "$LOGFILE"
        return 1
    }

    # Run natpmpc for TCP and UDP with retry logic
    TCP_SUCCESS=false
    UDP_SUCCESS=false
    
    if TCP_OUTPUT=$(run_natpmpc_with_retry tcp); then
        TCP_SUCCESS=true
    fi
    
    if UDP_OUTPUT=$(run_natpmpc_with_retry udp); then
        UDP_SUCCESS=true
    fi

    # Extract mapped port (prioritize UDP, fallback to TCP)
    MAPPED_PORT=""
    if [ "$UDP_SUCCESS" = true ]; then
        MAPPED_PORT=$(echo "$UDP_OUTPUT" | grep -oP 'Mapped public port \K[0-9]+' | tail -n1)
    elif [ "$TCP_SUCCESS" = true ]; then
        MAPPED_PORT=$(echo "$TCP_OUTPUT" | grep -oP 'Mapped public port \K[0-9]+' | tail -n1)
    fi

    if [[ -z "$MAPPED_PORT" || ! "$MAPPED_PORT" =~ ^[0-9]+$ ]]; then
        echo "Failed to map port or retrieve mapped port. Check natpmpc output above." | tee -a "$LOGFILE"
        echo "TCP Success: $TCP_SUCCESS, UDP Success: $UDP_SUCCESS" >> "$LOGFILE"
        
        # Run diagnostics on failure to help troubleshooting
        echo "Running diagnostics due to port mapping failure..." >> "$LOGFILE"
        run_diagnostics
    else
        echo "VPN port mapped successfully: $MAPPED_PORT to $LISTENING_PORT" | tee -a "$LOGFILE"
        if [ "$TCP_SUCCESS" = true ] && [ "$UDP_SUCCESS" = true ]; then
            echo "Both TCP and UDP mapping successful" >> "$LOGFILE"
        elif [ "$UDP_SUCCESS" = true ]; then
            echo "UDP mapping successful (TCP may have failed)" >> "$LOGFILE"
        else
            echo "TCP mapping successful (UDP may have failed)" >> "$LOGFILE"
        fi
    fi
    echo "" >> "$LOGFILE"

    sleep "$INTERVAL"
done
