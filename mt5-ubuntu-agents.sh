#!/bin/bash
set -e

TOTAL_CORES=$(nproc)
REQUESTED_CORES=${1:-$((TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1))}
[ "$REQUESTED_CORES" -ge "$TOTAL_CORES" ] && [ "$TOTAL_CORES" -gt 1 ] && REQUESTED_CORES=$((TOTAL_CORES - 1)) && echo "WARNING: Reserving 1 core for OS stability."
PW=${2:-"MetaTester"}
MQL5_LOGIN=$3
export DEBIAN_FRONTEND=noninteractive

echo "==> [1/6] Cleaning old installs..."
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
screen -ls 2>/dev/null | grep mt5 | awk '{print $1}' | xargs -I{} screen -X -S {} quit 2>/dev/null || true
rm -rf /opt/mt5* 2>/dev/null || true
apt-get remove --purge -y wine* winehq* 2>/dev/null || true
apt-get autoremove -y >/dev/null 2>&1 || true

echo "==> [2/6] Installing WineHQ Devel + dependencies..."
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
UBUNTU_VER=$(lsb_release -cs)
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/$UBUNTU_VER/winehq-$UBUNTU_VER.sources"
apt-get update -y >/dev/null
apt-get install -y --install-recommends winehq-devel xvfb screen wget net-tools cabextract >/dev/null 2>&1
echo "    -> $(wine --version)"

echo "==> [3/6] Setting up Swap & Network..."
if ! swapon --show | grep -q "/swapfile"; then
    fallocate -l 64G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress || true
    chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile || true
fi
cat <<EOF > /etc/sysctl.d/99-mt5.conf
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=30
vm.swappiness=60
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1 || true

echo "==> [4/6] Installing FULL MT5 Suite via official installer..."
export WINEPREFIX=/opt/mt5master
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
mkdir -p $WINEPREFIX

xvfb-run -a wineboot -u >/dev/null 2>&1
echo "    -> Wine prefix ready."

echo "    -> Downloading mt5setup.exe (using browser User-Agent to bypass CDN)..."
wget -q --show-progress \
    --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" \
    -O /tmp/mt5setup.exe \
    "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

echo "    -> Running installer (this installs ALL required DLLs and files, ~90s)..."
xvfb-run -a wine /tmp/mt5setup.exe /auto &
INSTALL_PID=$!

# Wait for the FULL installation directory with terminal64.dll to appear
for i in {1..36}; do
    if find $WINEPREFIX -name "metatester64.exe" 2>/dev/null | grep -q .; then
        echo "    -> Full MT5 installation detected after $((i*5))s!"
        break
    fi
    echo "    ...Installing ($((i*5))s)..."
    sleep 5
done

# Find where it was installed
MT5_INSTALL_DIR=$(find $WINEPREFIX -name "metatester64.exe" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$MT5_INSTALL_DIR" ]; then
    echo "ERROR: MT5 installation failed. Exiting."
    exit 1
fi
echo "    -> Installed at: $MT5_INSTALL_DIR"

# Kill installer process
kill $INSTALL_PID 2>/dev/null || true
pkill -f "mt5setup" 2>/dev/null || true
sleep 3

echo "==> [5/6] Cloning full installation to $REQUESTED_CORES agents..."
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

for P in $(seq $SP $EP); do
    echo "    -> Creating agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"

    # Copy the COMPLETE Wine prefix (with all DLLs and MT5 files)
    cp -r "$WINEPREFIX" "$AGENT_WP"

    # Find the agent exe in the cloned prefix
    AGENT_EX=$(find $AGENT_WP -name "metatester64.exe" 2>/dev/null | head -1)
    WIN_EX=$(echo "$AGENT_EX" | sed "s|$AGENT_WP/drive_c|C:|" | sed 's|/|\\|g')

    ACCOUNT_FLAG=""
    [ ! -z "$MQL5_LOGIN" ] && ACCOUNT_FLAG="/account:$MQL5_LOGIN"

    screen -dmS mt5-$P bash -c "
        export WINEPREFIX=$AGENT_WP
        export WINEARCH=win64
        export WINEDLLOVERRIDES='mscoree,mshtml='
        xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' \
            wine '$WIN_EX' /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG
    "
    echo "    -> Agent $P launched in screen session mt5-$P"
done

# Write startup script for reboots
STARTUP=/opt/mt5/start-all.sh
mkdir -p /opt/mt5
cat > $STARTUP << 'STARTEOF'
#!/bin/bash
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
sleep 3
STARTEOF

for P in $(seq $SP $EP); do
    AGENT_WP="/opt/mt5agent-$P"
    AGENT_EX=$(find $AGENT_WP -name "metatester64.exe" 2>/dev/null | head -1)
    WIN_EX=$(echo "$AGENT_EX" | sed "s|$AGENT_WP/drive_c|C:|" | sed 's|/|\\|g')
    ACCOUNT_FLAG=""
    [ ! -z "$MQL5_LOGIN" ] && ACCOUNT_FLAG="/account:$MQL5_LOGIN"
    cat >> $STARTUP << STARTEOF
screen -dmS mt5-$P bash -c "export WINEPREFIX=$AGENT_WP; export WINEARCH=win64; export WINEDLLOVERRIDES='mscoree,mshtml='; xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' wine '$WIN_EX' /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG"
STARTEOF
done

chmod +x $STARTUP
(crontab -l 2>/dev/null | grep -v mt5; echo "@reboot sleep 20 && $STARTUP") | crontab -

echo "==> [6/6] Waiting for agents to come online (up to 5 minutes)..."
for i in {1..60}; do
    COUNT=$(ss -tuln 2>/dev/null | grep -cE ":30[0-9]{2}" || true)
    if [ "$COUNT" -ge 1 ]; then
        echo ""
        echo "========================================="
        echo "✓ SUCCESS! $COUNT / $REQUESTED_CORES agents online!"
        ss -tuln | grep -E ":30[0-9]{2}" | awk '{print $5}'
        echo "========================================="
        [ ! -z "$MQL5_LOGIN" ] && echo "Cloud Selling: ENABLED for '$MQL5_LOGIN'"
        echo ""
        echo "Useful commands:"
        echo "  screen -ls              (see all agents)"
        echo "  screen -r mt5-3000      (watch agent live)"
        echo "  Ctrl+A then D           (detach from screen)"
        echo "  /opt/mt5/start-all.sh   (restart all after reboot)"
        echo "========================================="
        exit 0
    fi
    echo "    ...Waiting ($((i*5))s)..."
    sleep 5
done

echo "❌ TIMEOUT. Attach to see what Wine is doing: screen -r mt5-3000"
