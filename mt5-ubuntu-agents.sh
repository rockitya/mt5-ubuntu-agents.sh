#!/bin/bash

echo "Starting Fully Automated VPS Visual Desktop & MetaTester Setup..."

# 1. Nuke the firewall completely (As requested)
sudo ufw disable

# 2. Add 32-bit architecture and install dependencies
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y xfce4 xfce4-goodies tightvncserver novnc websockify wine64 wine32 wget unzip curl

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

# 7. Create working directory
mkdir -p ~/mt5_experiment
cd ~/mt5_experiment

# 8. Initialize Wine silently to the VNC display
export WINEARCH=win64
export DISPLAY=:1
echo "Initializing Wine environment..."
wineboot -u

# 9. Download the MetaTester Agent Setup
echo "Downloading MetaTester Agent Installer..."
wget -q -O mt5testersetup.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5testersetup.exe"

# 10. Download and Extract Intel SDE (Automated direct download)
echo "Downloading Intel SDE Emulator..."
wget -q -O sde-win.zip "https://downloadmirror.intel.com/813591/sde-external-9.33.0-2024-01-07-win.zip"
unzip -q sde-win.zip
mv sde-external-9.33.0-2024-01-07-win sde

# 11. Launch the installer inside the VNC Desktop
echo "Launching Setup Wizard inside noVNC..."
nohup wine ~/mt5_experiment/sde/sde.exe -hsw -- ~/mt5_experiment/mt5testersetup.exe > /dev/null 2>&1 &

# 12. Print final connection instructions
VPS_IP=$(curl -s ifconfig.me)

echo ""
echo "=========================================================================="
echo "✅ FULLY AUTOMATED SETUP COMPLETE!"
echo "=========================================================================="
echo "1. Open a web browser on your personal computer."
echo "2. Navigate to: http://${VPS_IP}:6080/vnc.html"
echo "3. Click 'Connect' and enter the password: mql5test"
echo ""
echo "The MetaTester Agent Setup wizard should already be open and waiting"
echo "for you on the visual desktop. (It may be slow/laggy due to emulation)."
echo "=========================================================================="
