#!/bin/sh


set -e

Err() {
  echo -e "[\033[0;31mERROR\033[0m|\033[1;30m$0\033[0m] $1"
  exit $1
}

Ok() {
  echo -e "[\033[0;32mOK   \033[0m|\033[1;30m$0\033[0m] $1"
}

Debug() {
  echo -e "[\033[0;33mDEBUG\033[0m|\033[1;30m$0\033[0m] $1"
}

Info() {
  echo -e "[\033[0;34mINFO \033[0m|\033[1;30m$0\033[0m] $1"
}


lsblk -d -n -o NAME,SIZE,MODEL
read -p "Enter the selected storage device: " DISK
DISK="/dev/$DISK"

read -p "This will erase all data on $DISK. Are you sure? (y/N) " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    Info "Aborting."
    exit 1
fi

Info "Wiping disk..."
wipefs --all --force "$DISK"
sgdisk --zap-all "$DISK"

Info "Creating base partitions..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 512MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary 512MiB 100%

if [[ "$DISK" =~ nvme[0-9]+n[0-9]+$ ]] \
|| [[ "$DISK" =~ mmcblk[0-9]+$ ]] \
|| [[ "$DISK" =~ md[0-9]+$ ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
elif [[ "$DISK" =~ sd[a-z]+$ ]]; then
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
else
    Err "Unsupported disk type: $DISK"
    exit 1
fi

Info "Formatting boot partition..."
mkfs.fat -F32 "$EFI_PART"

# Encryption (Optional)
read -p "Do you want to encrypt the root partition? (y/N) " ENCRYPT
if [[ "$ENCRYPT" == "y" ]]; then
    Info "Setting up LUKS encryption..."
    cryptsetup luksFormat "$ROOT_PART"
    cryptsetup open "$ROOT_PART" cryptroot
    LVM_PART="/dev/mapper/cryptroot"
else
    Info "Proceeding without encryption"
    LVM_PART="$ROOT_PART"
fi

Info "Creating LVM structure"
pvcreate "$LVM_PART"
vgcreate vg0 "$LVM_PART"
lvcreate -L 20G -n root vg0
lvcreate -L 200G -n home vg0

Info "Formatting LVM logical volumes"
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home

Debug "See formatted disk:"
lsblk
sleep 5

Info "Mounting system at /mnt"
mount /dev/vg0/root /mnt
mkdir -p /mnt/home /mnt/boot
mount "$EFI_PART" /mnt/boot
mount /dev/vg0/home /mnt/home

Info "Bootstrapping basic arch system"
pacstrap -K /mnt base base-devel linux linux-firmware lvm2 git grub efibootmgr networkmanager
genfstab -U /mnt > /mnt/etc/fstab

Info "Copying installation scripts"
cp -r * /mnt/root/

Info "Running initial installation in chroot environment"
arch-chroot /mnt <<EOF
sed -i 's/\(block\) \(filesystem\)/\1 encrypt lvm2 \2/' /etc/mkinitcpio.conf
mkinitcpio -P

passwd
pass
pass

systemctl enable NetworkManager

mkdir -p /boot/EFI
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
sleep 10

echo "./install.sh" >> /root/.bash_profile
EOF

Ok "finished initial setup! rebooting..."
umount -R /mnt
reboot
