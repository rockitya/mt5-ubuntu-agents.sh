#!/bin/bash

CORES=$1
PASSWORD=$2
MQL5_LOGIN=$3

if [ -z "$CORES" ] || [ -z "$PASSWORD" ]; then
    echo "Error: Missing required arguments. Usage: curl -sSL <url> | bash -s <CORES> <PASSWORD> [MQL5_LOGIN]"
    exit 1
fi

sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export WINEDLLOVERRIDES="mscoree=;mshtml="
export WINEDEBUG=-all

sudo dpkg --add-architecture i386 > /dev/null 2>&1
sudo -E apt-get update -yqq > /dev/null 2>&1
sudo -E apt-get install -yqq wine wine64 wine32 xvfb wget winbind net-tools > /dev/null 2>&1

mkdir -p ~/mt5-agents > /dev/null 2>&1
cd ~/mt5-agents > /dev/null 2>&1
wget -q -nc -O metatester64.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/metatester64.exe" > /dev/null 2>&1

killall -9 wineserver metatester64.exe wine Xvfb xvfb-run > /dev/null 2>&1
sleep 2

nohup Xvfb :99 -screen 0 1024x768x16 > /dev/null 2>&1 &
export DISPLAY=:99
sleep 2

START_PORT=3000

for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    DIR="$HOME/mt5-agents/node_$PORT"
    export WINEPREFIX="$DIR"
    
    rm -rf "$DIR" > /dev/null 2>&1
    mkdir -p "$DIR" > /dev/null 2>&1
    cp metatester64.exe "$DIR/" > /dev/null 2>&1
    
    wineboot -u > /dev/null 2>&1
    sleep 2
    
    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        
        cat <<REG > "$DIR/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        wine regedit "$DIR/cloud.reg" > /dev/null 2>&1
    fi
    
    nohup wine "$DIR/metatester64.exe" /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG > "$DIR/agent.log" 2>&1 &
    sleep 3
done

sudo sync > /dev/null 2>&1
sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "Setup Complete. Agents are running silently."
