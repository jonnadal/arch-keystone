#!/usr/bin/env bash
# vim: set expandtab tabstop=4 shiftwidth=4:
set -euo pipefail
cd "$(realpath $(dirname "$0"))"

# Start with sanity checks.
if [ $EUID -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi
if [ $# -ne 2 ]; then
  echo "Usage:   $0 target_device hostname" >&2
  echo "Example: $0 /dev/sda      laptop"   >&2
  exit 1
fi

# Now shared inputs and constants.
TARGET_DEV="$1"
HOSTNAME="$2"
DAILY_USER="daily"
if [[ "$TARGET_DEV" =~ nvme ]]; then
  BOOT_PART="${TARGET_DEV}p1"
  CRYPT_PART="${TARGET_DEV}p2"
else
  BOOT_PART="${TARGET_DEV}1"
  CRYPT_PART="${TARGET_DEV}2"
fi

step1_prep_disk() {
    # TODO 
    
    # Warning message.
    cat <<EOF
    *** WARNING: This will ERASE ALL DATA on $TARGET_DEV! ***
    Type 'ERASE' or 'SKIP' to continue.
EOF
    read -r CONFIRM
    if [ "$CONFIRM" = 'SKIP' ]]; then
      echo 'Skipping.'
      return
    elif [ "$CONFIRM" != 'ERASE' ]; then
      echo 'Aborted.'
      exit 1
    fi

    # Partition.
    parted --script "$TARGET_DEV" \
      mklabel gpt \
      mkpart primary fat32 1MiB 32GiB \
      set 1 esp on \
      mkpart primary 32GiB 95%

    # Format partitions.
    mkfs.fat -F32 "$BOOT_PART"
    cryptsetup luksFormat "$CRYPT_PART"
    cryptsetup open "$CRYPT_PART" cryptroot
    mkfs.btrfs /dev/mapper/cryptroot

    # Create subvolumes.
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@os
    btrfs subvolume create /mnt/@data
    umount /mnt
}

step2_configure_outside_chroot() {
    # TODO Link syncthing and tailscale configuration from @data/host/$HOSTNAME/{syncthing,tailscale}.

    # Mount subvolumes.
    cryptsetup open "$CRYPT_PART" cryptroot || true
    mount -o subvol=@os /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/boot
    mount "$BOOT_PART" /mnt/boot
    mkdir -p "/mnt/home/$DAILY_USER/data/"
    mount -o subvol=@data /dev/mapper/cryptroot "/mnt/home/$DAILY_USER/data"
    mkdir -p "/mnt/home/$DAILY_USER/data/localhost/$HOSTNAME/"{dot-ssh,syncthing,tailscale}

    # Enable wifi and optimize mirrors.
    rfkill unblock wlan bluetooth
    iwctl
    if command -v reflector >/dev/null 2>&1; then
      reflector --country 'United States' --latest 10 --sort rate --save /etc/pacman.d/mirrorlist \
          || echo 'reflector failed, using default mirrors.'
    fi

    # Install base system (with a retry loop for timeouts).
    MAX_ATTEMPTS=5
    for attempt in $(seq 1 $MAX_ATTEMPTS); do
      echo "pacstrap attempt $attempt of $MAX_ATTEMPTS."
      if pacstrap /mnt base btrfs-progs efibootmgr iwd linux linux-firmware sudo; then
        break
      elif [ $attempt -eq $MAX_ATTEMPTS ]; then
        echo 'Too many failures. Exiting.'
        exit 1
      else
        echo 'Failed. Retrying in 10 seconds.'
        sleep 10
      fi
    done

    # Generate fstab with compression and without access time.
    genfstab -U /mnt > /mnt/etc/fstab
    sync
    sed -i 's|subvol=/@os|subvol=/@os,noatime,compress=zstd|g' /mnt/etc/fstab
    sed -i 's|subvol=/@data|subvol=/@data,noatime,compress=zstd|g' /mnt/etc/fstab

    # And transfer the update script to a temporary location.
    mkdir -p /mnt/tmp
    cp aks-* /usr/local/bin/
}

step3_configure_inside_chroot() {
    # TODO Evaluate whether efibootmgr can be run in step 2.
    # TODO Move /boot/loader and /etc/fstab setup to step 2.
    # TODO Move sudoers update to step 2.

    arch-chroot /mnt /bin/bash <<EOF
    set -ex

    # Set timezone and locale.
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    hwclock --systohc
    sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen
    echo 'LANG=en_US.UTF-8' > /etc/locale.conf

    # Set hostname
    echo '$HOSTNAME' > /etc/hostname
    HOSTNAME='$HOSTNAME'

    # Configure mkinitcpio for LUKS and btrfs
    sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf

    # Set up systemd-boot and register with UEFI.
    bootctl install
    bootctl update || true
    if command -v efibootmgr >/dev/null 2>&1; then
        echo "Attempting to register boot entry with UEFI..."
        if efibootmgr >/dev/null 2>&1; then
            # Remove existing entries and add new.
	        efibootmgr | awk '/Arch/ { match($0, /[0-9]+/, m); print m[0] }' |xargs -I {} efibootmgr -b {} -B
            efibootmgr --create --disk '$TARGET_DEV' --part 1 --loader /EFI/systemd/systemd-bootx64.efi --label "Arch Keystone" --verbose
        else
            echo 'WARNING: EFI variables not supported. QEMU VM? Boot entry may need manual configuration.'
        fi
    fi

    # Create loader.conf
    cat > /boot/loader/loader.conf <<LOADER
    default keystone
    timeout 3
    console-mode max
    editor no
LOADER

    # Get UUIDs.
    ROOT_UUID='$(blkid -s UUID -o value $CRYPT_PART)'
    BTRFS_UUID='$(blkid -s UUID -o value /dev/mapper/cryptroot)'

    # Create boot entry.
    cat > /boot/loader/entries/keystone.conf <<ENTRY
    title   Arch Keystone
    linux   /vmlinuz-linux
    initrd  /initramfs-linux.img
    options cryptdevice=UUID=\$ROOT_UUID:cryptroot root=UUID=\$BTRFS_UUID rootflags=subvol=@os rw quiet
ENTRY

    # Create /etc/crypttab.
    cat > /etc/crypttab <<CRYPT
    cryptroot UUID=\$ROOT_UUID none luks
CRYPT

    # Generate initramfs.
    mkinitcpio -P

    # No root password.
    passwd -l root

    # Create daily user and links to data that should survive @os refreshes.
    useradd -m -G wheel $DAILY_USER || true
    echo "$DAILY_USER:$DAILY_USER" | chpasswd
    chown -R $DAILY_USER:$DAILY_USER /home/$DAILY_USER
    ln -snf "/home/$DAILY_USER/data/localhost/$HOSTNAME/dot-ssh" \
            "/home/$DAILY_USER/.ssh"
    ln -snf "/home/$DAILY_USER/data/localhost/$HOSTNAME/dot-mozilla/ \
            "/home/$DAILY_USER/.mozilla"

    # Enable sudo for wheel group. Requires `sudo` package.
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    # Enable systemd services before reboot.
    systemctl enable systemd-networkd systemd-resolved

    /usr/local/bin/aks-update
EOF
}

# TODO set up a sane .vimrc, .profile and niri cfg
# TODO rebuild adder again just to make sure this stuff works

set -x
step1_prep_disk
step2_configure_outside_chroot
step3_configure_inside_chroot

set +x
echo ''
echo 'You can now reboot into your bootstrapped system.'
echo 'If you need to make further changes, arch-chroot into /mnt before rebooting.'
