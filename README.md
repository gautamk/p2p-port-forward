# p2p-port-forward
A lightweight shell script for unRAID that enables automatic NAT-PMP port forwarding in a Docker container running a torrent client (like qBittorrent) through a VPN connection — using unRAID's built-in WireGuard support.

Tested with ProtonVPN and `linuxserver/qbittorrent`, but should work with other torrent clients as well. No Gluetun or custom VPN Docker containers required.

---

## Features

- Automatically maps rotating VPN P2P ports to your torrent client's listening port
- Uses NAT-PMP (with `natpmpc`) to request forwarded ports from your VPN provider
- Installs `libnatpmp` inside your container if missing
- **Enhanced reliability** with retry logic for installation and port mapping failures
- **Automatic diagnostics** to help troubleshoot connectivity and configuration issues
- **Better error handling** with detailed logging for troubleshooting
- Minimal configuration required

---

## Requirements

- **ProtonVPN - paid plan** (or another VPN with NAT-PMP and dynamic port support)
- **Torrent Docker container** (e.g. `linuxserver/qbittorrent`)
- **User Scripts plugin** in unRAID
- unRAID 6.12+ (for built-in WireGuard support)

---

## Setup Instructions

### Step 1 – Get Your WireGuard Config from ProtonVPN

1. Log into your ProtonVPN account online.
2. Go to **Downloads** > **WireGuard Config**.
3. Choose a **P2P-enabled server**.
4. Enable **NAT-PMP** before downloading.
5. Save the `.conf` file.

### Step 2 – Import WireGuard into unRAID

1. Go to **Settings > VPN Manager** in unRAID.
2. Click **Import Tunnel** and upload your `.conf`.
3. In **Advanced View**, fix the **Peer Name** (remove any `#`).
4. Note the **Local tunnel network pool** (e.g. `10.2.0.0`) — copy this down, and we'll change the last digit to `.1` (e.g. `10.2.0.1`) for use in the script.
5. Apply and **enable** the tunnel.

### Step 3 – Attach Torrent Container to VPN Tunnel

1. Go to **Docker > Edit** your torrent container.
2. Set **Network Type** to `Custom: wg0` (or whatever your tunnel is named).
3. In the qBittorrent webUI, go to **Settings > Connection**:
    - Disable: “Use UPnP / NAT-PMP”
    - Set port to `6881` (default, but configurable)

### Step 4 – Add the Script

1. Install the **User Scripts** plugin from the unRAID Community Applications page (if not already installed).
2. Go to **Plugins > User Scripts**.
3. Add a new script (e.g., `vpn_torrent_forwarding`).
4. Paste in the contents of **p2p-port-forward-script.sh**
5. Modify these variables at the top of the script to match your setup:

   ```bash
   CONTAINER="qbittorrent"
   LISTENING_PORT="6881"
   WGTUNNEL="10.2.0.1"
   LOGFILE="/var/log/natpmp_forward.log"
   LOG_RETENTION_DAY=3
   INTERVAL=45
6. Save and set the script to run At Startup of Array.
7. Reboot your array or run the script manually to test.

### Verifying that it's working

1. Check the live output in your terminal:

    ```
    tail -f /var/log/natpmp_forward.log
    ```

3. You should see a confirmation message, for example:

    ```
    VPN port mapped successfully: 54321 to 6881
    ```

4. Within 5 minutes, your torrent client should acknowledge a fully connected client.  For example, qBittorrent will show an orange flame at the bottom for a firewalled connection. This should change to a green globe after the script runs successfully and the client updates.

---

## Troubleshooting

If your torrent client still shows as "Firewalled" despite successful port mapping, try these steps:

### Common Issues and Solutions

#### 1. Script shows successful mapping but client still firewalled

**Check the log for diagnostic information:**
```bash
tail -f /var/log/natpmp_forward.log
```

Look for diagnostic messages that appear periodically. The script automatically runs diagnostics every ~15 cycles to help identify issues:
- Network connectivity to WireGuard gateway
- External DNS resolution
- qBittorrent listening port validation

#### 2. libnatpmp installation failures

The script now includes retry logic for `libnatpmp` installation. If you see repeated installation failures:

1. Check if your container has internet access
2. Verify the container is using an Alpine-based image (required for `apk` package manager)
3. Try restarting the container and script

#### 3. Network connectivity issues

**Verify WireGuard tunnel is working:**
```bash
# Test from within your torrent container
docker exec qbittorrent ping -c 3 10.2.0.1

# Check container network configuration
docker exec qbittorrent ip addr show
```

#### 4. Port configuration mismatch

**Verify qBittorrent settings:**
1. In qBittorrent WebUI, go to **Settings > Connection**
2. Ensure "Use UPnP / NAT-PMP port forwarding from my router" is **DISABLED**
3. Verify the listening port matches your script's `LISTENING_PORT` value (default: 6881)
4. Check that qBittorrent is actually listening on the configured port

#### 5. VPN server issues

**Try a different ProtonVPN server:**
1. Some P2P servers may have temporary issues
2. Switch to a different P2P-enabled server (e.g., Switzerland #920)
3. Ensure NAT-PMP is enabled in your ProtonVPN config

#### 6. Container restart issues

If the script stops working after a container restart:
1. The enhanced script now automatically reinstalls `libnatpmp` if needed
2. Check the logs for "natpmpc no longer available, reinstalling..." messages
3. Allow a few cycles for the script to recover

### Advanced Troubleshooting

#### Manual NAT-PMP Test

Test NAT-PMP manually from within your container:
```bash
docker exec qbittorrent natpmpc -a 0 6881 udp 1200 -g 10.2.0.1
```

Expected output should include:
```
Mapped public port XXXXX to internal port 6881
```

#### Check Script Configuration

Verify your script variables match your setup:
- `CONTAINER`: Exact name of your torrent container
- `LISTENING_PORT`: Should match qBittorrent's listening port
- `WGTUNNEL`: Should be your WireGuard gateway (typically ends in .1)

#### Container Network Debugging

```bash
# Check container is using VPN network
docker inspect qbittorrent | grep NetworkMode

# Verify container IP is in VPN range
docker exec qbittorrent ip route show
```

If none of these steps resolve the issue, check the detailed diagnostic logs that the script now generates automatically.
