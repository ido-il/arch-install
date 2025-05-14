#!/bin/sh
# Welcome to my installation script!
# This script was made to containerize all the installation logic into a single
# file and run it with 0 interruptions (unless an error arises
#
# Any required configuration is defined in the `#Variables` section by the user
# that includes bit flags to enable/disable installation features.
#
# Im also assuming that the system running this script already had the following
# packages installed during the live-iso installation phase:
# - base
# - base-devel
# - git
# - networkmanager
# - iproute2  # in `base`
# - dnsmasq
# - wget
# - unzip

set -e

# only run with root permission
if [ "$EUID" -ne 0 ]; then Err "Install script must run with root privileges!"
    exit 1
fi

#==============================
# Variables
#==============================
# NOTE: 0: Ignore | 1: Apply
ZONE=""
HOSTNAME="MooseBox"

NM_RANDOMIZE_MAC=0

USE_WIFI=0
WIFI_SSID=""
WIFI_PASS=""  # dont forget to hide this after the install :)

PACKAGES=$(echo "

" | sed 's/\n/ /' | sed 's/,//g' | sed 's/#.*$//')

#==============================
# Util functions
#==============================
# logging
Err() {
  echo -e "[\033[0;31mERROR\033[0m $1"
}

Ok() {
  echo -e "[\033[0;32mOK   \033[0m $1"
}

Debug() {
  echo -e "[\033[0;33mDEBUG\033[0m $1"
}

Info() {
  echo -e "[\033[0;34mINFO \033[0m $1"
}

# additional util
uncomment() {
  sed -i "s|^\s*#\s*\($2\s*\)|\1|" "$1"
}


#==============================
# Network
#==============================
Info "NetworkManager config"
tee /etc/NetworkManager/NetworkManager.conf <<EOF
[main]
auth-polkit=true
dhcp=internal
dns=dnsmasq
EOF

mkdir -p /etc/NetworkManager/conf.d

[[ $NM_RANDOMIZE_MAC -eq 1 ]] && tee /etc/NetworkManager/conf.d/00-macrandomize.conf <<EOF
[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=preserve
EOF

# TODO: research networkmanager for more optional configuration options

Info "dnsmasq configuration"
tee /etc/NetworkManager/dnsmasq.d/custom.conf <<EOF
listen-address=127.0.0.1

bind-interfaces
interface=lo

domain-needed
bogus-priv
no-hosts
no-poll

# against DNS poisoning
dns-forward-max=150
cache-size=1000
EOF

Info "Ensure \`NetworkManager\` and \`dnsmasq\` are enabled and active"
systemctl enable --now NetworkManager.service
systemctl enable --now dnsmasq.service

if [[ $USE_WIFI -eq 1 ]]; then
    Info "Connecting to preset wifi host"
    nmcli dev wifi con $WIFI_SSID --pass $WIFI_PASS
fi

# TODO: add firewall configuration here

Info "Ensure network connection"
getent hosts archlinux.org
ping -c 5 archlinux.org

echo "$HOSTNAME" > /etc/hostname

#==============================
# Package manager
#==============================
Info "Generate updated mirrorlist"
pacman -Sy reflector
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
reflector --country "Israel" --protocol https --sort rate --save /etc/pacman.d/mirrorlist
tee -a /etc/pacman.d/mirrorlist <<EOF

## Fallback to global mirrors
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
Server = https://mirror.nus.edu.sg/archlinux/\$repo/os/\$arch
Server = https://mirror.kernel.org/archlinux/\$repo/os/\$arch
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://ftpmirror.infania.net/mirror/archlinux/\$repo/os/\$arch
EOF

Info "Define pacman.conf"
tee /etc/pacman.conf <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
HoldPkg = pacman glibc

ParallelDownloads = 5
VerbosePkgLists
CheckSpace
Color
ILoveCandy  # :)

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

Info "Build yay from source"
git clone https://aur.archlinux.org/yay.git /tmp/yay
cd /tmp/yay
makepkg -si
cd $HOME
rm -rf /tmp/yay

Info "Synchronize databases"
pacman -Syu --noconfirm

Ok "package manager config done!"

#==============================
# Packages!
#==============================
yay -S
#==============================
# Locale
#==============================
uncomment /etc/locale.gen "en_US.UTF-8 UTF-8"
uncomment /etc/locale.gen "en_US USI-8559-1"
locale-gen

Info "Download my fav nerdfont :3"
mkdir -p /usr/local/share/font
mkdir -p /tmp/font
wget -o /tmp/font/FONT.zip "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/BigBlueTerminal.zip"
unzip /tmp/font/FONT.zip
mv /tmp/font/BigBlueTermPlusNerdFontMono-Regular.ttf /usr/local/share/font
rm -rf /tmp/font  # cleanup

#==============================
# Clock
#==============================
hwclock
