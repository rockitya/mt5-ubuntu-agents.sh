#!/bin/bash

echo "Starting VPS Visual Desktop & Wine Setup (Firewall Disabled)..."

# 1. Nuke the firewall completely (As requested)
sudo ufw disable

# 2. Add 32-bit architecture and install dependencies
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y xfce4 xfce4-goodies tightvncserver novnc websockify wine64 wine32 wget xz-utils curl

# 3. Setup VNC Server password (Setting password to: mql5test)
mkdir -p ~/.vnc
echo "mql5test" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# 4. Configure VNC to use the XFCE desktop environment
cat << 'EOF' > ~/.vnc/xstartup
#!/bin/bash
xrdb $HOME/.Xresources
startxfce4 &
EOF
chmod +x ~/.vnc/xstartup

# 5. Start VNC server (killing any stuck instances first)
vncserver -kill :1 2>/dev/null || true
vncserver :1 -geometry 1280x720 -depth 24

# 6. Start noVNC Web Bridge in the background
websockify -D --web=/usr/share/novnc/ 6080 localhost:5901

# 7. Set up Wine and download the MetaTester Agent Setup
mkdir -p ~/mt5_experiment
cd ~/mt5_experiment

# Initialize Wine registry
WINEARCH=win64 wineboot

# Download official MQL5 Strategy Tester Agent Installer (NOT the full MT5 terminal)
echo "Downloading MetaTester Agent Installer..."
wget -O mt5testersetup.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5testersetup.exe"

# 8. Print final connection instructions
VPS_IP=$(curl -s ifconfig.me)

echo ""
echo "=========================================================================="
echo "✅ SETUP COMPLETE! FIREWALL IS DOWN & DESKTOP IS LIVE."
echo "=========================================================================="
echo "1. Open a web browser on your personal computer."
echo "2. Navigate to: http://${VPS_IP}:6080/vnc.html"
echo "3. Click 'Connect' and enter the password: mql5test"
echo ""
echo "=========================================================================="
echo "NEXT STEPS (Do this INSIDE the visual desktop):"
echo "=========================================================================="
echo "1. Open the Web Browser inside your new VNC desktop."
echo "2. Go to: https://www.intel.com/content/www/us/en/download/684897/"
echo "3. Download the WINDOWS version (sde-external-...-win.tar.xz)."
echo "4. Extract the SDE folder to your home directory."
echo "5. Open the terminal emulator inside the VNC desktop and run:"
echo "   wine /path/to/sde/sde.exe -hsw -- ~/mt5_experiment/mt5testersetup.exe"
echo ""
echo "WARNING: The installer will bypass the AVX check due to the emulator."
echo "Running the installed metatester.exe normally afterward will still crash."
echo "=========================================================================="
