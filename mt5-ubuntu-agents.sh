#!/bin/bash
set -e

TOTAL_CORES=$(nproc)
REQUESTED_CORES=${1:-$((TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1))}
if [ "$REQUESTED_CORES" -ge "$TOTAL_CORES" ] && [ "$TOTAL_CORES" -gt 1 ]; then
    echo "WARNING: Reserving 1 core for OS stability."
    REQUESTED_CORES=$((TOTAL_CORES - 1))
fi

PW=${2:-"MetaTester"}
MQL5_LOGIN=$3
export DEBIAN_FRONTEND=noninteractive

echo "==> [1/5] Cleaning old installs..."
pkill -9 -f metatester64.exe 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
screen -ls 2>/dev/null | grep mt5 | awk '{print $1}' | xargs -I{} screen -X -S {} quit 2>/dev/null || true
rm -rf /opt/mt5 2>/dev/null || true
apt-get remove --purge -y wine* 2>/dev/null || true
apt-get autoremove -y >/dev/null 2>&1 || true

echo "==> [2/5] Installing Wine + Xvfb + Screen..."
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
UBUNTU_VER=$(lsb_release -cs)
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/$UBUNTU_VER/winehq-$UBUNTU_VER.sources"
apt-get update -y >/dev/null
apt-get install -y --install-recommends winehq-stable xvfb screen wget net-tools >/dev/null 2>&1
echo "    -> $(wine --version) installed."

echo "==> [3/5] Setting up agent directory & Wine prefix..."
mkdir -p /opt/mt5/exe
export WINEPREFIX=/opt/mt5/wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="

xvfb-run -a wineboot -u >/dev/null 2>&1
echo "    -> Wine prefix ready."

echo "    -> Downloading metatester64.exe..."
wget --show-progress -q \
    -O "/opt/mt5/exe/metatester64.exe" \
    "https://github.com/rockitya/mt5-ubuntu-agents.sh/raw/main/metatester64.exe"
chmod +x /opt/mt5/exe/metatester64.exe

echo "==> [4/5] Launching $REQUESTED_CORES agents in screen sessions..."
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

# Write the reboot startup script
cat > /opt/mt5/start-all.sh << STARTEOF
#!/bin/bash
export WINEPREFIX=/opt/mt5/wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
pkill -9 -f metatester64.exe 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
sleep 2
STARTEOF

for P in $(seq $SP $EP); do
    ACCOUNT_FLAG=""
    [ ! -z "$MQL5_LOGIN" ] && ACCOUNT_FLAG="/account:$MQL5_LOGIN"

    # Launch each agent in its own detached screen session
    screen -dmS mt5-$P bash -c "
        export WINEPREFIX=/opt/mt5/wine
        export WINEARCH=win64
        export WINEDLLOVERRIDES='mscoree,mshtml='
        xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' \
            wine explorer /desktop=agent$P,1024x768 \
            'C:\mt5\exe\metatester64.exe' \
            /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG
    "
    echo "    -> Agent $P started in screen session 'mt5-$P'"

    # Add to startup script
    cat >> /opt/mt5/start-all.sh << STARTEOF
screen -dmS mt5-$P bash -c "export WINEPREFIX=/opt/mt5/wine; export WINEARCH=win64; export WINEDLLOVERRIDES='mscoree,mshtml='; xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' wine explorer /desktop=agent$P,1024x768 'C:\mt5\exe\metatester64.exe' /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG"
STARTEOF
done

chmod +x /opt/mt5/start-all.sh

# Add @reboot cron so agents survive VPS restart
(crontab -l 2>/dev/null | grep -v mt5; echo "@reboot sleep 15 && /opt/mt5/start-all.sh") | crontab -
echo "    -> Cron @reboot entry added for auto-restart."

echo "==> [5/5] Waiting for agents to come online (up to 5 minutes)..."
for i in {1..60}; do
    COUNT=$(ss -tuln 2>/dev/null | grep -cE ":30[0-9]{2}" || true)
    if [ "$COUNT" -ge 1 ]; then
        echo ""
        echo "========================================="
        echo "✓ SUCCESS! $COUNT agent(s) running!"
        ss -tuln | grep -E ":30[0-9]{2}" | awk '{print $5}'
        echo "========================================="
        [ ! -z "$MQL5_LOGIN" ] && echo "Cloud Selling: ENABLED for '$MQL5_LOGIN'"
        echo ""
        echo "Useful commands:"
        echo "  See all agents:  screen -ls"
        echo "  Watch agent log: screen -r mt5-3000"
        echo "  Detach from log: Ctrl+A then D"
        echo "  Restart all:     /opt/mt5/start-all.sh"
        echo "========================================="
        exit 0
    fi
    echo "    ...Waiting for ports ($((i*5))s)..."
    sleep 5
done

echo "❌ TIMEOUT. Check screen sessions:"
screen -ls
echo "Attach to agent 3000 to see live output: screen -r mt5-3000"
