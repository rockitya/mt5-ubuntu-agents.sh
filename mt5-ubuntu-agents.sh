#!/bin/bash
set -e

# MT5 Ubuntu Cloud Agents — Full Setup Script
# Usage: bash mt5-ubuntu-agents.sh [CORES] [PASSWORD] [MQL5_LOGIN]
# Example: bash mt5-ubuntu-agents.sh 7 Prem@1996 rcktya

TOTAL_CORES=$(nproc)
if [ -z "$1" ]; then
    REQUESTED_CORES=$((TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1))
else
    REQUESTED_CORES=$1
    if [ "$REQUESTED_CORES" -ge "$TOTAL_CORES" ] && [ "$TOTAL_CORES" -gt 1 ]; then
        echo "WARNING: Reserving 1 core for OS stability."
        REQUESTED_CORES=$((TOTAL_CORES - 1))
    fi
fi

PW=${2:-"MetaTester"}
MQL5_LOGIN=$3
export DEBIAN_FRONTEND=noninteractive

echo "============================================="
echo " MT5 Cloud Agent Setup"
echo " Cores: $REQUESTED_CORES | Login: ${MQL5_LOGIN:-none}"
echo "============================================="

# --- [1/8] WIPE ---
echo "==> [1/8] NUCLEAR WIPE..."
screen -ls 2>/dev/null | grep mt5 | awk '{print $1}' | xargs -I{} screen -X -S {} quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
sleep 3
rm -rf /opt/mt5* /tmp/mt5setup.exe /tmp/gdrive* 2>/dev/null || true
apt-get remove --purge -y wine* winehq* 2>/dev/null || true
apt-get autoremove -y >/dev/null 2>&1 || true
crontab -l 2>/dev/null | grep -v mt5 | grep -v clear-ram | crontab - 2>/dev/null || true
rm -f /usr/local/bin/clear-ram-cache.sh 2>/dev/null || true
echo "    -> Done."

# --- [2/8] WINE DEVEL ---
echo "==> [2/8] Installing WineHQ Devel..."
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
UBUNTU_VER=$(lsb_release -cs)
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/$UBUNTU_VER/winehq-$UBUNTU_VER.sources"
apt-get update -y >/dev/null
apt-get install -y --install-recommends winehq-devel xvfb screen wget net-tools cabextract python3-pip curl >/dev/null 2>&1
pip3 install -q --upgrade gdown
echo "    -> $(wine --version)"

# --- [3/8] SWAP 64GB PERSISTENT ---
echo "==> [3/8] Setting up 64GB Swap (persistent across reboots)..."
swapoff -a 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true
fallocate -l 64G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress || true
chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
cat > /etc/sysctl.d/99-mt5.conf << 'EOF'
vm.swappiness=10
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=30
net.core.somaxconn=1024
fs.file-max=1000000
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1 || true
echo "    -> Swap active and persisted in /etc/fstab"
free -h | grep Swap

# --- [4/8] RAM CACHE CRON ---
echo "==> [4/8] Scheduling RAM cache auto-clear every 30 minutes..."
cat > /usr/local/bin/clear-ram-cache.sh << 'EOF'
#!/bin/bash
sync
echo 3 > /proc/sys/vm/drop_caches
EOF
chmod +x /usr/local/bin/clear-ram-cache.sh
/usr/local/bin/clear-ram-cache.sh
(crontab -l 2>/dev/null | grep -v clear-ram-cache; echo "*/30 * * * * /usr/local/bin/clear-ram-cache.sh") | crontab -
echo "    -> RAM cache cleared now. Auto-clear every 30 min via cron."

# --- [5/8] MT5 FULL INSTALL ---
echo "==> [5/8] Downloading mt5setup.exe from Google Drive..."
export WINEPREFIX=/opt/mt5master
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
mkdir -p $WINEPREFIX

xvfb-run -a wineboot -u >/dev/null 2>&1
echo "    -> Wine prefix initialized."

GDRIVE_ID="1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC"

# Method 1: gdown (handles large file virus-scan bypass automatically)
echo "    -> Trying gdown..."
gdown --fuzzy "https://drive.google.com/file/d/${GDRIVE_ID}/view?usp=drive_link" \
    -O /tmp/mt5setup.exe 2>/dev/null || true

FILESIZE=$(stat -c%s /tmp/mt5setup.exe 2>/dev/null || echo 0)

# Method 2: curl with Google Drive export URL
if [ "$FILESIZE" -lt 1000000 ]; then
    echo "    -> gdown failed (${FILESIZE} bytes). Trying curl..."
    rm -f /tmp/mt5setup.exe /tmp/gdrive_cookies.txt
    curl -c /tmp/gdrive_cookies.txt -s \
        "https://drive.google.com/uc?export=download&id=${GDRIVE_ID}" \
        -o /tmp/gdrive_page.html
    CONFIRM=$(grep -oP 'confirm=\K[^&"]+' /tmp/gdrive_page.html 2>/dev/null | head -1 || echo "t")
    curl -Lb /tmp/gdrive_cookies.txt \
        "https://drive.google.com/uc?export=download&id=${GDRIVE_ID}&confirm=${CONFIRM}" \
        -o /tmp/mt5setup.exe
    FILESIZE=$(stat -c%s /tmp/mt5setup.exe 2>/dev/null || echo 0)
fi

# Method 3: wget with cookie confirmation
if [ "$FILESIZE" -lt 1000000 ]; then
    echo "    -> curl failed (${FILESIZE} bytes). Trying wget..."
    rm -f /tmp/mt5setup.exe /tmp/gdrive_cookies.txt
    wget -q --save-cookies /tmp/gdrive_cookies.txt --keep-session-cookies \
        "https://drive.google.com/uc?export=download&id=${GDRIVE_ID}" \
        -O /tmp/gdrive_page.html
    CONFIRM=$(grep -o 'confirm=[^&"]*' /tmp/gdrive_page.html 2>/dev/null | head -1 | cut -d= -f2 || echo "t")
    wget -q --show-progress --load-cookies /tmp/gdrive_cookies.txt \
        "https://drive.google.com/uc?export=download&id=${GDRIVE_ID}&confirm=${CONFIRM}" \
        -O /tmp/mt5setup.exe
    FILESIZE=$(stat -c%s /tmp/mt5setup.exe 2>/dev/null || echo 0)
fi

# Final size check
if [ "$FILESIZE" -lt 1000000 ]; then
    echo "ERROR: All download methods failed. File is only ${FILESIZE} bytes."
    echo ""
    echo "  Manual fix — run this on your LOCAL PC then re-run this script:"
    echo "  scp mt5setup.exe root@$(hostname -I | awk '{print $1}'):/tmp/mt5setup.exe"
    exit 1
fi
echo "    -> mt5setup.exe ready: $(du -sh /tmp/mt5setup.exe | cut -f1)"

echo "    -> Running silent MT5 install (wait up to 5 minutes)..."
xvfb-run -a wine /tmp/mt5setup.exe /auto &
INSTALL_PID=$!

for i in {1..60}; do
    if find $WINEPREFIX -name "metatester64.exe" 2>/dev/null | grep -q .; then
        echo "    -> Full MT5 installation confirmed after $((i*5))s!"
        break
    fi
    echo "    ...Installing ($((i*5))s / 300s)..."
    sleep 5
done

MT5_DIR=$(find $WINEPREFIX -name "metatester64.exe" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$MT5_DIR" ]; then
    echo "ERROR: MT5 installation failed. metatester64.exe not found. Exiting."
    exit 1
fi
WIN_EX="$(echo "$MT5_DIR" | sed "s|$WINEPREFIX/drive_c|C:|" | sed 's|/|\\|g')\\metatester64.exe"
echo "    -> Installed at: $WIN_EX"
kill $INSTALL_PID 2>/dev/null || true
pkill -f mt5setup 2>/dev/null || true
sleep 3

# --- [6/8] CLEAR CLOUD.PING ---
echo "==> [6/8] Clearing Cloud.Ping cache for clean cloud connection..."
WINEPREFIX="$WINEPREFIX" WINEARCH=win64 wine reg add \
    "HKEY_USERS\\S-1-5-18\\Software\\MetaQuotes Software\\Cloud.Ping" \
    /ve /t REG_SZ /d "" /f >/dev/null 2>&1 || true
echo "    -> Cloud.Ping cache cleared."

# --- [7/8] CLONE & LAUNCH AGENTS ---
echo "==> [7/8] Cloning master prefix and launching $REQUESTED_CORES agents..."
mkdir -p /opt/mt5
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

cat > /opt/mt5/start-all.sh << 'STARTEOF'
#!/bin/bash
screen -ls 2>/dev/null | grep mt5 | awk '{print $1}' | xargs -I{} screen -X -S {} quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
sleep 5
STARTEOF

for P in $(seq $SP $EP); do
    echo "    -> Deploying agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"
    cp -r "$WINEPREFIX" "$AGENT_WP"

    AGENT_EX=$(find $AGENT_WP -name "metatester64.exe" 2>/dev/null | head -1)
    AGENT_WIN_EX="$(echo "$AGENT_EX" | sed "s|$AGENT_WP/drive_c|C:|" | sed 's|/|\\|g')"

    # Clear Cloud.Ping in each agent prefix
    WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg add \
        "HKEY_USERS\\S-1-5-18\\Software\\MetaQuotes Software\\Cloud.Ping" \
        /ve /t REG_SZ /d "" /f >/dev/null 2>&1 || true

    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg add \
            "HKEY_CURRENT_USER\\Software\\MetaQuotes\\MetaTester" \
            /v "Login" /t REG_SZ /d "$MQL5_LOGIN" /f >/dev/null 2>&1 || true
        WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg add \
            "HKEY_CURRENT_USER\\Software\\MetaQuotes\\MetaTester" \
            /v "SellComputingResources" /t REG_DWORD /d "1" /f >/dev/null 2>&1 || true
        CONFIG_DIR="$AGENT_WP/drive_c/users/Public/AppData/Roaming/MetaQuotes/Tester"
        mkdir -p "$CONFIG_DIR"
        printf '[Tester]\nPort=%s\nPassword=%s\n[Cloud]\nLogin=%s\nSellComputingResources=1\n' \
            "$P" "$PW" "$MQL5_LOGIN" > "$CONFIG_DIR/metatester.ini"
    fi

    screen -dmS mt5-$P bash -c "
        export WINEPREFIX=$AGENT_WP
        export WINEARCH=win64
        export WINEDLLOVERRIDES='mscoree,mshtml='
        xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' \
            wine '$AGENT_WIN_EX' /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG
    "
    echo "      -> Agent $P launched: screen mt5-$P"

    echo "screen -dmS mt5-$P bash -c \"export WINEPREFIX=$AGENT_WP; export WINEARCH=win64; export WINEDLLOVERRIDES='mscoree,mshtml='; xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' wine '$AGENT_WIN_EX' /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG\"" >> /opt/mt5/start-all.sh
done

chmod +x /opt/mt5/start-all.sh
(crontab -l 2>/dev/null | grep -v mt5; \
    echo "@reboot sleep 20 && /usr/local/bin/clear-ram-cache.sh && /opt/mt5/start-all.sh") | crontab -
echo "    -> @reboot cron added."

# --- [8/8] VERIFY ---
echo "==> [8/8] Waiting for agents to come online (up to 5 minutes)..."
for i in {1..60}; do
    COUNT=$(ss -tuln 2>/dev/null | grep -cE ":30[0-9]{2}" || true)
    if [ "$COUNT" -ge 1 ]; then
        echo ""
        echo "============================================="
        echo "  SUCCESS: $COUNT / $REQUESTED_CORES agents online!"
        ss -tuln | grep -E ":30[0-9]{2}" | awk '{print $5}'
        echo "============================================="
        [ ! -z "$MQL5_LOGIN" ] && echo "  Cloud: ENABLED for account '$MQL5_LOGIN'"
        echo ""
        echo "  Commands:"
        echo "    screen -ls                          (list all sessions)"
        echo "    screen -r mt5-3000                  (watch agent live)"
        echo "    Ctrl+A then D                       (detach from screen)"
        echo "    /opt/mt5/start-all.sh               (restart all agents)"
        echo "    /usr/local/bin/clear-ram-cache.sh   (clear RAM manually)"
        echo ""
        echo "  After 3 minutes check cloud ping:"
        echo "    screen -r mt5-3000"
        echo "    (look for: Network server agentX.mql5.net ping XX ms)"
        echo "    Also verify: https://cloud.mql5.com"
        echo "============================================="
        exit 0
    fi
    echo "    ...Waiting ($((i*5))s / 300s)..."
    sleep 5
done

echo "TIMEOUT: Attach to see live output: screen -r mt5-3000"
