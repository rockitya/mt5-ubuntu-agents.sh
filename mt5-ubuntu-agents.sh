#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# MT5 + 8 SDE-EMULATED AGENT FARM (NO APT LOCK CLEARING)
# - Master MetaTester GUI (noVNC control)
# - 8 headless agents w/ Intel SDE (HSW,SKX,ICL,SAP,KNL,GLC,SLM,NTM)
# - 64GB fixed swap, auto-boot systemd services
# ============================================================

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"

# Agent configuration
AGENT_COUNT=8
AGENT_BASE_PORT=3000
AGENT_PASS="mt5agent"
AGENT_DIR="/opt/mt5-agents"
MASTER_WINEPREFIX="/root/.wine-master"
AGENT_WINEPREFIX_BASE="/root/.wine-agent-base"
SDE_DIR="/opt/intel-sde"

FILE_ID="1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC"
GDRIVE_URL="https://drive.usercontent.google.com/download?id=1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC&export=download&authuser=0"
SETUP_FILE="/root/mt5setup.exe"

echo "============================================="
echo " MT5 + 8 SDE-AGENT FARM SETUP (NO APT LOCKS)"
echo " Server : $SERVER_IP"
echo " Master: https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo " Agents: $AGENT_BASE_PORT-$((AGENT_BASE_PORT+AGENT_COUNT-1))"
echo "============================================="

# ------------------------------------------------------------
# [0/10] FULL CLEANUP (NO APT LOCK HANDLING)
# ------------------------------------------------------------
echo "==> [0/10] Complete cleanup"
pkill -9 -f metatester64 tester-agent wine Xvfb x11vnc websockify 2>/dev/null || true
screen -wipe 2>/dev/null || true

# Kill systemd services
systemctl stop metatester-sde-agent@* 2>/dev/null || true
systemctl disable metatester-sde-agent@* 2>/dev/null || true

# Remove all prefixes and directories
rm -rf /opt/mt5* "$MASTER_WINEPREFIX" "$AGENT_WINEPREFIX_BASE" "$AGENT_DIR" "$SDE_DIR"
rm -rf /root/.wine*

# Remove swap
swapoff /swapfile 2>/dev/null || true
swapoff -a 2>/dev/null || true
sed -i '/|\/swapfile/d' /etc/fstab 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

# Purge packages (no lock handling)
apt-get remove --purge -y wine* x11vnc novnc python3-websockify 2>/dev/null || true
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get autoclean -y >/dev/null 2>&1 || true

echo "    -> Cleanup complete"

# ------------------------------------------------------------
# [1/10] DISABLE FIREWALL
# ------------------------------------------------------------
echo "==> [1/10] Disable firewall"
ufw disable 2>/dev/null || true
iptables -F && iptables -X && iptables -t nat -F && iptables -t mangle -F
iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT
ip6tables -F && ip6tables -X && ip6tables -P INPUT ACCEPT && ip6tables -P FORWARD ACCEPT && ip6tables -P OUTPUT ACCEPT
systemctl stop firewalld 2>/dev/null || true && systemctl disable firewalld 2>/dev/null || true
echo "    -> Firewall disabled"

# ------------------------------------------------------------
# [2/10] INSTALL WINE + DEPENDENCIES
# ------------------------------------------------------------
echo "==> [2/10] Install Wine + dependencies"
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends \
    software-properties-common ca-certificates gnupg2 lsb-release \
    wget curl openssl python3 python3-pip xvfb screen cabextract \
    x11vnc novnc python3-websockify net-tools util-linux procps \
    >/dev/null

dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
UBUNTU_VER="$(lsb_release -cs)"
wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"
apt-get update -y >/dev/null
apt-get install -y --install-recommends winehq-devel >/dev/null
echo "    -> Wine $(wine --version)"

# ------------------------------------------------------------
# [3/10] 64GB SWAP + MEMORY TUNING
# ------------------------------------------------------------
echo "==> [3/10] 64GB swap setup"
swapoff -a 2>/dev/null || true
sed -i '/|\/swapfile/d' /etc/fstab 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

if fallocate -l 64G /swapfile 2>/dev/null; then
    echo "    -> fallocate success"
else
    dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress
fi
chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

cat > /etc/sysctl.d/99-mt5.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=80
vm.dirty_ratio=15
vm.dirty_background_ratio=5
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null

echo "    -> Memory: $(free -h | grep -E "Mem|Swap")"

# ------------------------------------------------------------
# [4/10] DOWNLOAD MT5 INSTALLER
# ------------------------------------------------------------
echo "==> [4/10] Download MT5 installer"
FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
if [ "$FILESIZE" -lt 1000000 ]; then
    python3 -m pip install --upgrade pip gdown >/dev/null 2>&1
    rm -f "$SETUP_FILE" 2>/dev/null || true
    gdown --fuzzy "$GDRIVE_URL" -O "$SETUP_FILE" || \
    gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "$SETUP_FILE" || \
    gdown "${FILE_ID}" -O "$SETUP_FILE"
    
    FILESIZE=$(stat -c%s "$SETUP_FILE")
    if [ "$FILESIZE" -lt 1000000 ]; then
        echo "ERROR: MT5 download failed (${FILESIZE} bytes)"; exit 1
    fi
    echo "    -> MT5 installer: $(du -sh "$SETUP_FILE" | cut -f1)"
fi

# ------------------------------------------------------------
# [5/10] MASTER METATESTER INSTALL (GUI Controller)
# ------------------------------------------------------------
echo "==> [5/10] Master MetaTester install"
mkdir -p /opt/mt5-master
export WINEPREFIX="$MASTER_WINEPREFIX" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all

rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true
Xvfb :90 -screen 0 1280x900x24 >/tmp/xvfb-master.log 2>&1 &
XVFB_MASTER_PID=$!
sleep 3

DISPLAY=:90 wineboot -u >/dev/null 2>&1
sleep 5

echo "    -> Installing master MetaTester..."
DISPLAY=:90 wine "$SETUP_FILE" /auto >/tmp/mt5-master-install.log 2>&1 &
INSTALL_PID=$!

# Wait for installation (up to 10min)
FOUND=0
for i in {1..120}; do
    MTEST_MASTER="$(find "$MASTER_WINEPREFIX" -iname 'metatester64.exe' 2>/dev/null | head -1)"
    MT5_EX="$(find "$MASTER_WINEPREFIX" -iname 'terminal64.exe' 2>/dev/null | head -1)"
    [ -n "$MTEST_MASTER" ] && FOUND=1 && break
    echo "    ... waiting ($((i*5))s/600s)"
    sleep 5
done

kill "$INSTALL_PID" 2>/dev/null || true; wait "$INSTALL_PID" 2>/dev/null || true
kill "$XVFB_MASTER_PID" 2>/dev/null || true; wait "$XVFB_MASTER_PID" 2>/dev/null || true

MTEST_MASTER="$(find "$MASTER_WINEPREFIX" -iname 'metatester64.exe' | head -1)"
if [ -z "$MTEST_MASTER" ]; then
    echo "ERROR: Master install failed"; tail -20 /tmp/mt5-master-install.log; exit 1
fi
echo "    -> Master: $MTEST_MASTER"

# ------------------------------------------------------------
# [6/10] INTEL SDE DOWNLOAD + INSTALL
# ------------------------------------------------------------
echo "==> [6/10] Intel SDE auto-download"
mkdir -p "$SDE_DIR"

# Try official Intel page first, fallback to direct URL
SDE_URL=""
if command -v curl >/dev/null; then
    SDE_URL=$(curl -s "https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html" | \
        grep -o 'https://downloadmirror\.intel\.com/[0-9]*/[^"]*lin\.tar\.xz' | head -1)
fi

if [ -z "$SDE_URL" ]; then
    # Fallback direct URL (update if needed)
    SDE_URL="https://downloadmirror.intel.com/761308/sde-external-9.26.2024- Zahid-offline-lin.tar.xz"
fi

wget -qO /tmp/sde.tar.xz "$SDE_URL" || {
    echo "ERROR: SDE download failed"
    echo "Manual: https://www.intel.com/content/www/us/en/download/684897/"
    echo "Upload: scp sde-external-*.tar.xz root@$SERVER_IP:/root/"
    exit 1
}

tar xf /tmp/sde.tar.xz --strip-components=1 -C "$SDE_DIR"
rm /tmp/sde.tar.xz
ln -sf "$SDE_DIR/sde" /usr/local/bin/sde64

echo "    -> SDE: $(sde64 --version 2>/dev/null || echo "installed")"

# ------------------------------------------------------------
# [7/10] AGENT BASE INSTALL
# ------------------------------------------------------------
echo "==> [7/10] Agent base install"
mkdir -p "$AGENT_DIR"
cp -r "$MASTER_WINEPREFIX" "$AGENT_WINEPREFIX_BASE"

export WINEPREFIX="$AGENT_WINEPREFIX_BASE"
rm -f /tmp/.X91-lock /tmp/.X11-unix/X91
Xvfb :91 -screen 0 1024x768x16 >/tmp/xvfb-agent.log 2>&1 &
sleep 3
DISPLAY=:91 wineboot -u >/dev/null 2>&1
sleep 3

echo "    -> Installing agent base..."
DISPLAY=:91 wine "$SETUP_FILE" /autoagent >/tmp/mt5-agent-install.log 2>&1 &
sleep 90  # Agent install takes longer

MTEST_AGENT="$(find "$AGENT_WINEPREFIX_BASE" -path '*/MetaTrader 5/tester64.exe' | head -1 || \
               find "$AGENT_WINEPREFIX_BASE" -iname 'metatester64.exe' | head -1)"

if [ -z "$MTEST_AGENT" ]; then
    echo "ERROR: Agent install failed"; tail -20 /tmp/mt5-agent-install.log; exit 1
fi
echo "    -> Agent base: $MTEST_AGENT"

# ------------------------------------------------------------
# [8/10] 8 SYSTEMD AGENT SERVICES w/ SDE
# ------------------------------------------------------------
echo "==> [8/10] Create $AGENT_COUNT SDE agents"
declare -A SDE_ARCHS=([0]=hsw [1]=skx [2]=icl [3]=sap [4]=knl [5]=glc [6]=slm [7]=ntm)

for i in $(seq 0 $((AGENT_COUNT-1))); do
    AGENT_PORT=$((AGENT_BASE_PORT + i))
    AGENT_INST="$AGENT_DIR/agent-$i"
    SDE_ARCH="${SDE_ARCHS[$i]:-hsw}"
    
    cat > /etc/systemd/system/metatester-sde-agent-$i.service <<EOF
[Unit]
Description=MT5 SDE Agent $i ($SDE_ARCH)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$AGENT_INST
Environment="WINEPREFIX=$AGENT_INST" "WINEARCH=win64" "WINEDLLOVERRIDES=mscoree,mshtml=" "WINEDEBUG=-all"
ExecStartPre=/bin/bash -c 'rm -rf $AGENT_INST && cp -r $AGENT_WINEPREFIX_BASE $AGENT_INST'
ExecStartPre=/usr/bin/Xvfb :$((100+i)) -screen 0 1024x768x16 -ac -noreset -nolisten tcp
ExecStart=$SDE_DIR/sde --${SDE_ARCH} -- wine "$MTEST_AGENT" /agent /install /address:$SERVER_IP:$AGENT_PORT /password:$AGENT_PASS
ExecStopPost=/bin/bash -c 'pkill -f "DISPLAY=:$((100+i))"'
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
done

systemctl daemon-reload
for i in $(seq 0 $((AGENT_COUNT-1))); do
    systemctl enable metatester-sde-agent-$i.service
    systemctl start metatester-sde-agent-$i.service
done

sleep 5
echo "    -> Agent status:"
systemctl list-units --state=active metatester-sde-agent-* | grep running | wc -l || true
netstat -tlnp | grep ":${AGENT_BASE_PORT}" || true

# ------------------------------------------------------------
# [9/10] MASTER NOVNC LAUNCHER
# ------------------------------------------------------------
echo "==> [9/10] Master noVNC setup"
mkdir -p /opt/mt5-master
VNC_CERT="/opt/mt5-master/novnc.pem"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$VNC_CERT" -out "$VNC_CERT" \
    -days 3650 -subj "/CN=$SERVER_IP" >/dev/null 2>&1

cat > /opt/mt5-master/open-master-vnc.sh <<EOF
#!/bin/bash
set -euo pipefail
pkill -9 -f x11vnc websockify 2>/dev/null || true
sleep 2

rm -f /tmp/.X10-lock /tmp/.X11-unix/X10
Xvfb :10 -screen 0 1920x1080x24 >/tmp/xvfb-master-vnc.log 2>&1 &
sleep 3

x11vnc -display :10 -rfbport $VNC_PORT -passwd "$VNC_PASS" \\
    -forever -shared -noxdamage -noxfixes -bg -o /tmp/x11vnc-master.log &
sleep 2

websockify -D --web=/usr/share/novnc/ --cert="$VNC_CERT" \\
    $NOVNC_PORT localhost:$VNC_PORT >/tmp/websockify-master.log 2>&1 &

export DISPLAY=:10 WINEPREFIX=$MASTER_WINEPREFIX WINEARCH=win64 WINEDEBUG=-all
wine "$MTEST_MASTER" >/tmp/master-metatester.log 2>&1 &

echo ""
echo "=============================================="
echo " MASTER + 8 SDE AGENTS RUNNING"
echo "=============================================="
echo " Browser: https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1"
echo " Password: $VNC_PASS"
echo " Agents: 127.0.0.1:${AGENT_BASE_PORT}-${AGENT_BASE_PORT}+7 ($AGENT_PASS)"
echo "=============================================="
EOF

chmod +x /opt/mt5-master/open-master-vnc.sh

# ------------------------------------------------------------
# [10/10] UTILITIES + CLEANUP
# ------------------------------------------------------------
echo "==> [10/10] Utilities"
cat > /usr/local/bin/clear-ram-cache.sh <<'EOF'
#!/bin/bash
sync && echo 1 > /proc/sys/vm/drop_caches && echo 3 > /proc/sys/vm/drop_caches
EOF
chmod +x /usr/local/bin/clear-ram-cache.sh
/usr/local/bin/clear-ram-cache.sh

cat > /opt/mt5-master/farm-status.sh <<EOF
#!/bin/bash
echo "=== MT5 SDE FARM STATUS ==="
echo "Active agents: \$(systemctl list-units --state=active metatester-sde-agent-* | grep running | wc -l)/$AGENT_COUNT"
echo "Listening ports:"
netstat -tlnp 2>/dev/null | grep ":$AGENT_BASE_PORT" || ss -tlnp | grep ":$AGENT_BASE_PORT"
echo ""
echo "Master log: tail -f /tmp/master-metatester.log"
echo "Agent 0 log: journalctl -u metatester-sde-agent-0 -f"
EOF
chmod +x /opt/mt5-master/farm-status.sh

# Launch master GUI
echo "==> Starting master GUI..."
/opt/mt5-master/open-master-vnc.sh

cat <<DONE

==============================================
✅ COMPLETE: 8 SDE-AGENT MT5 FARM READY (NO APT LOCKS)
==============================================
MASTER GUI: https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1
VNC Password: $VNC_PASS

AGENT FARM (Strategy Tester > Agents tab):
  Local: 127.0.0.1:${AGENT_BASE_PORT}-${AGENT_BASE_PORT}+7
  Pass:  $AGENT_PASS

COMMANDS:
  Status:        /opt/mt5-master/farm-status.sh
  Restart agent: systemctl restart metatester-sde-agent-0
  Master GUI:    /opt/mt5-master/open-master-vnc.sh  
  Clear RAM:     clear-ram-cache.sh

SDE EMULATION:
  Agent 0: hsw (Haswell)    Agent 4: knl (Knights Landing)
  Agent 1: skx (Skylake-X)  Agent 5: glc (Goldmont)
  Agent 2: icl (Ice Lake)   Agent 6: slm (Snow Ridge)  
  Agent 3: sap (Sapphire)   Agent 7: ntm (Tremont)

SCALING: Deploy to 8+ VMs, add IPs in Tester > Agents tab
==============================================
DONE
