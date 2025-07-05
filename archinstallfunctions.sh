install_configs() {
    print_step "Installing system configurations..."
    # Copy system-wide configurations
    if [[ -d "./cachyos-settings" ]]; then
        # Only copy directories from CachyOS-Settings, ignore root-level files
        for item in ./cachyos-settings/*/; do
            if [[ -d "$item" ]]; then
                # Get the directory name without the path
                dirname=$(basename "$item")
                echo "Copying directory: $dirname"
                cp -r "$item" "$INSTALL_POINT/"
            fi
        done
    else
        echo "Warning: CachyOS-Settings directory not found, skipping system configs"
    fi

    # Copy user-specific configurations
    if [[ -d "./home" ]]; then
        print_step "Installing user configurations for $username..."
        # Ensure the user's home directory exists
        mkdir -p "$INSTALL_POINT/home/$username"
        # Copy the files
        rsync -a ./home/ "$INSTALL_POINT/home/$username/"
        # Fix ownership of the copied files
        arch-chroot "$INSTALL_POINT" chown -R "$username:$username" "/home/$username"
    else
        echo "Warning: ./home directory not found, skipping user configs"
    fi
}

mount_home() {
    # Only proceed if home_partition is defined
    if [[ -z "$home_partition" ]]; then
        echo "Skipping home mount: \$home_partition is not set."
        return 0
    fi

    # Define target mount point
    local target="$INSTALL_POINT/home"

    print_step "Mounting home partition $home_partition to $target..."
    mkdir -p "$target"

    # Detect filesystem type
    local fstype
    fstype=$(blkid -s TYPE -o value "$home_partition") || {
        echo "Error: could not detect filesystem type of $home_partition"
        return 1
    }

    # Choose mount options based on fs type
    local opts
    case "$fstype" in
        btrfs)
            opts=$BTRFS_MOUNT_OPTIONS
            ;;
        bcachefs)
            opts=$BCACHEFS_MOUNT_OPTIONS
            ;;
        f2fs)
            opts=$F2FS_MOUNT_OPTIONS
            ;;
        ext4)
            opts=$EXT4_MOUNT_OPTIONS
            ;;
        *)
            echo "Warning: unknown fs type '$fstype' – mounting without extra options."
            opts=""
            ;;
    esac

    # Perform the mount
    if [[ -n "$opts" ]]; then
        mount -o "$opts" "$home_partition" "$target"
    else
        mount "$home_partition" "$target"
    fi

    # Check mount success
    if mountpoint -q "$target"; then
        echo "Home partition mounted successfully."
    else
        echo "Error: failed to mount $home_partition on $target"
        return 1
    fi
}

format_partitions() {
    # Optionally format the boot partition based on variable
    if [[ "$format_boot_partition" == "yes" ]]; then
        print_step "Formatting boot partition $boot_partition as FAT32..."
        mkfs.fat -F32 "$boot_partition"
    else
        echo "Skipping formatting of $boot_partition."
    fi

    # Handle root partition formatting based on encryption setting
    if [[ "$encryption" == "yes" ]]; then
        print_step "Encrypting root partition $root_partition with LUKS..."
        cryptsetup luksFormat "$root_partition"
        cryptsetup open "$root_partition" "$CRYPTROOT_NAME"
        root_device="/dev/mapper/$CRYPTROOT_NAME"
    else
        root_device="$root_partition"
    fi

    # Format root partition based on selected filesystem
    case "$filesystem" in
        "ext4")
            print_step "Formatting root partition $root_device as ext4..."
            mkfs.ext4 "$root_device"
            ;;
        "btrfs")
            print_step "Formatting root partition $root_device as btrfs..."
            mkfs.btrfs -f "$root_device"
            ;;
        "f2fs")
            print_step "Formatting root partition $root_device as f2fs with options $F2FS_FORMAT_FEATURES..."
            mkfs.f2fs -f -o "$F2FS_FORMAT_FEATURES" "$root_device"
            ;;
        "bcachefs")
            print_step "Formatting root partition $root_device as bcachefs..."
            mkfs.bcachefs -f "$root_device"
            ;;
        *)
            echo "Invalid filesystem choice. Defaulting to ext4."
            mkfs.ext4 "$root_device"
            ;;
    esac
}


mount_partitions() {
    # Mount the root partition
    bootmountpoint=${bootmountpoint:-/boot}
    print_step "Mounting root partition $root_device to $INSTALL_POINT..."
    mkdir -p $INSTALL_POINT
    case $filesystem in
        "ext4")
            mount -o $EXT4_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;
        "btrfs")
            mount -o $BTRFS_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;
        "f2fs")
            mount -o $F2FS_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;
        "bcachefs")
            mount -o $BCACHEFS_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;
        *)
            mount -o $EXT4_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;
    esac

    # Mount the boot partition
    print_step "Mounting boot partition $boot_partition to $INSTALL_POINT$bootmountpoint..."
    mkdir -p $INSTALL_POINT$bootmountpoint
    mount $boot_partition $INSTALL_POINT$bootmountpoint
}

install_base_system() {
    # Base packages including the chosen kernel and base-devel
    base_packages="base base-devel dhcpcd $kernel_package power-profiles-daemon pacman nano git sudo linux-firmware efibootmgr networkmanager bluez bluez-utils htop fastfetch wireplumber git mkinitcpio reflector zsh zsh-theme-powerlevel10k cachyos-rate-mirrors gamescope-session-git"

    # Additional packages based on the chosen filesystem
    case $filesystem in
        "btrfs")
            base_packages="$base_packages btrfs-progs"
            ;;
        "f2fs")
            base_packages="$base_packages f2fs-tools"
            ;;
        "bcachefs")
            base_packages="$base_packages bcachefs-tools"
            ;;
    esac

    # Desktop environment packages
    case $desktop_environment in
        "myky")
            base_packages="$base_packages cachyos-gaming-meta steam sddm xorg wayland plasma sddm konsole dolphin octopi paru htop neofetch konsole dolphin cmake make partitionmanager $adpackages"
            ;;
        "gnome")
            base_packages="$base_packages sddm gnome $adpackages"
            ;;
        "kde")
            base_packages="$base_packages sddm xorg wayland plasma sddm konsole dolphin $adpackages"
            ;;
        "xfce")
            base_packages="$base_packages sddm xfce4 $adpackages"
            ;;
        "mate")
            base_packages="$base_packages sddm mate $adpackages"
            ;;
        "mini")
            base_packages="cachyos-rate-mirrors base dhcpcd networkmanager sudo mkinitcpio $kernel_package"
            ;;
        "lxqt")
            base_packages="$base_packages sddm lxqt xorg $adpackages"
            ;;
        "pico")
            base_packages="cachyos-rate-mirrors mkinitcpio $adpackages $kernel_package"
            ;;
        *)
            echo "No valid desktop environment selected. Only base system will be installed."
            ;;
    esac

    # Use pacstrap to install the base system and additional packages
    print_step "Installing base system and additional packages with pacstrap..."
    pacstrap -P $pacman_config $INSTALL_POINT $base_packages
}

chroot_into_system() {
    # Generate fstab
    print_step "Generating fstab..."
    genfstab -U $INSTALL_POINT >> $INSTALL_POINT/etc/fstab

    # Configure LUKS TRIM if enabled
    configure_luks_trim

    # Chroot into the new system and execute commands
    print_step "Chrooting into the new system at $INSTALL_POINT..."
    arch-chroot $INSTALL_POINT /bin/bash <<EOF
# Basic setup
print_step "Setting up timezone and clock..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

# Localization
print_step "Setting up localization..."
echo "$LOCALE UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Initramfs configuration
print_step "Configuring initramfs..."
if [ "$encryption" = yes ]; then
    if [ "$filesystem" = "btrfs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block sd-encrypt btrfs filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
    elif [ "$filesystem" = "bcachefs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block sd-encrypt filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(bcachefs)/' /etc/mkinitcpio.conf
    elif [ "$filesystem" = "f2fs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block sd-encrypt filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(f2fs)/' /etc/mkinitcpio.conf
    fi
else
    if [ "$filesystem" = "btrfs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block btrfs filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
    elif [ "$filesystem" = "bcachefs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(bcachefs)/' /etc/mkinitcpio.conf
    elif [ "$filesystem" = "f2fs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(f2fs)/' /etc/mkinitcpio.conf
    fi
fi
mkinitcpio -P

# Set root password
echo "Setting root password..."
echo "root:$root_password" | chpasswd

# Create user account and set password
echo "Creating user $username..."
useradd -m -G wheel -s /bin/zsh $username
echo "Setting password for $username..."
echo "$username:$user_password" | chpasswd

# Configure sudo for the wheel group
echo "Configuring sudo for the wheel group..."
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Enable services
print_step "Enabling services..."
systemctl enable NetworkManager
systemctl enable fstrim.timer
systemctl enable reflector.timer
systemctl enable power-profiles-daemon.service
systemctl enable irqbalance
systemctl enable thermald
systemctl enable dhcpcd
systemctl enable sddm

# Performance tuning
print_step "Applying performance tweaks..."
cat << SYSCTL > /etc/sysctl.d/99-performance.conf
# improvements
vm.swappiness = $SWAPPINESS
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
kernel.split_lock_mitigate=0

# Network improvements
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_congestion_control = $TCP_CONGESTION_CONTROL
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# File system and app improvements
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
SYSCTL

# Set up zsh for the user
print_step "Setting up user environment..."
mkdir -p /home/$username/.config
echo "source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme" >> /home/$username/.zshrc
cat << ZSHRC >> /home/$username/.zshrc
# Basic zsh configuration
setopt autocd
setopt interactive_comments
setopt extended_glob

# History settings
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory
setopt hist_ignore_all_dups
setopt hist_ignore_space

# Basic completions
autoload -Uz compinit
compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Key bindings
bindkey -e  # Use emacs key bindings
bindkey '^[[H' beginning-of-line                 # Home key
bindkey '^[[F' end-of-line                       # End key
bindkey '^[[3~' delete-char                      # Delete key
bindkey '^[[A' history-beginning-search-backward # Up arrow
bindkey '^[[B' history-beginning-search-forward  # Down arrow

# Aliases
alias ls='ls --color=auto'
alias ll='ls -la'
alias grep='grep --color=auto'
alias ip='ip -color=auto'
# alias sudo='sudo-rs'

# Add colors to man pages
export LESS_TERMCAP_mb=$'\e[1;32m'
export LESS_TERMCAP_md=$'\e[1;32m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_so=$'\e[01;33m'
export LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_us=$'\e[1;4;31m'
ZSHRC

# Fix ownership of user home directory and files
echo "Fixing ownership of user home directory..."
chown -R $username:$username /home/$username

# Enable periodic TRIM for SSDs
print_step "Setting up SSD TRIM..."
systemctl enable fstrim.timer

localectl set-keymap $KEYMAP
journalctl --vacuum-size=100M
touch /etc/pacman.d/cachyos-mirrorlist
touch /etc/pacman.d/cachyos-v3-mirrorlist
touch /etc/pacman.d/cachyos-v4-mirrorlist
cachyos-rate-mirrors
chmod 644 /etc/pacman.conf
systemctl mask systemd-coredump.service
systemctl mask systemd-coredump.socket
EOF
}

sysdboot() {
arch-chroot $INSTALL_POINT /bin/bash <<EOF
# Bootloader
print_step "Installing bootloader..."
bootctl install

# Create boot entry
mkdir -p /boot/loader/entries
KERNEL_NAME=\$(echo $kernel_package | sed 's/linux-//')
if [ "$encryption" = yes ]; then
    # For encrypted systems, use UUID of the LUKS container
    LUKS_UUID=\$(blkid -s UUID -o value "$root_partition")
    cat << EOL > /boot/loader/entries/arch.conf
title   Arch Linux ($kernel_package)
linux   /vmlinuz-$kernel_package
initrd  /initramfs-$kernel_package.img
options rd.luks.uuid=\$LUKS_UUID rd.luks.name=\$LUKS_UUID=$CRYPTROOT_NAME root=/dev/mapper/$CRYPTROOT_NAME rw $KERNEL_PARAMS
EOL

else
    # For unencrypted systems, use PARTUUID
    ROOT_PARTUUID=\$(blkid -s PARTUUID -o value "$root_device")
    cat << EOL > /boot/loader/entries/arch.conf
title   MYKYcorp ($kernel_package)
linux   /vmlinuz-$kernel_package
initrd  /initramfs-$kernel_package.img
options root=PARTUUID=\$ROOT_PARTUUID rw $KERNEL_PARAMS
EOL

fi

cat > /boot/loader/loader.conf <<EOL
timeout 0
console-mode max
editor yes
default @saved
EOL
EOF
}

install_grub() {
    # Pre‑resolve identifiers based on encryption
    local luks_uuid=""
    local root_partuuid=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
        if [ -z "$root_partuuid" ]; then
            echo "Error: could not determine PARTUUID of $root_device"
            return 1
        fi
    fi
    arch-chroot "$INSTALL_POINT" /bin/bash <<EOF
    pacman -S --noconfirm grub efibootmgr os-prober
    if [ "$encryption" = "yes" ]; then
        # Pass the UUID variable into the environment for encrypted systems
        LUKS_UUID="$luks_uuid"
        # Use systemd-based encryption parameter syntax for sd-encrypt hook
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=/dev/mapper/${CRYPTROOT_NAME} rd.luks.name=\$LUKS_UUID=${CRYPTROOT_NAME} ${KERNEL_PARAMS}\"|" /etc/default/grub
        sed -i 's|^#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
        # Add cryptodisk modules to preload
        sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos luks cryptodisk"|' /etc/default/grub
    else
        # For unencrypted systems, use PARTUUID
        ROOT_PARTUUID="$root_partuuid"
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=PARTUUID=\$ROOT_PARTUUID ${KERNEL_PARAMS}\"|" /etc/default/grub
    fi
    sed -i 's|^#GRUB_TIMEOUT=[0-9]\+|GRUB_TIMEOUT=3|' /etc/default/grub
    sed -i 's|^#GRUB_DISABLE_OS_PROBER=false|GRUB_DISABLE_OS_PROBER=false|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT_STYLE=hidden|#GRUB_TIMEOUT_STYLE=hidden|' /etc/default/grub
    grub-install \
      --target=x86_64-efi \
      --efi-directory=/boot \
      --bootloader-id=MYKYcorp_GRUB \
      --recheck $grubstate
    grub-mkconfig -o /boot/grub/grub.cfg
    chmod -R g-rwx,o-rwx /boot/efi
EOF
}

install_grubcursed() {
    # For devices with 32-bit UEFI but 64-bit CPU
    local luks_uuid=""
    local root_partuuid=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
        if [ -z "$root_partuuid" ]; then
            echo "Error: could not determine PARTUUID of $root_device"
            return 1
        fi
    fi
    arch-chroot "$INSTALL_POINT" /bin/bash <<EOF
    pacman -S --noconfirm grub efibootmgr os-prober
    if [ "$encryption" = "yes" ]; then
        # Pass the UUID variable into the environment for encrypted systems
        LUKS_UUID="$luks_uuid"
        # Use systemd-based encryption parameter syntax for sd-encrypt hook
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=/dev/mapper/${CRYPTROOT_NAME} rd.luks.name=\$LUKS_UUID=${CRYPTROOT_NAME} ${KERNEL_PARAMS}\"|" /etc/default/grub
        sed -i 's|^#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
        # Add cryptodisk modules to preload
        sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos luks cryptodisk"|' /etc/default/grub
    else
        # For unencrypted systems, use PARTUUID
        ROOT_PARTUUID="$root_partuuid"
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=PARTUUID=\$ROOT_PARTUUID ${KERNEL_PARAMS}\"|" /etc/default/grub
    fi
    sed -i 's|^#GRUB_TIMEOUT=[0-9]\+|GRUB_TIMEOUT=3|' /etc/default/grub
    sed -i 's|^#GRUB_DISABLE_OS_PROBER=false|GRUB_DISABLE_OS_PROBER=false|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT_STYLE=hidden|#GRUB_TIMEOUT_STYLE=hidden|' /etc/default/grub
    grub-install \
      --target=i386-efi \
      --efi-directory=/boot \
      --bootloader-id=MYKYcorp_GRUB \
      --recheck $grubstate
    grub-mkconfig -o /boot/grub/grub.cfg
    chmod -R g-rwx,o-rwx /boot/efi
EOF
}

install_grub_bios() {
    # Pre-resolve identifiers and disk device
    local luks_uuid=""
    local root_partuuid=""
    local disk=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
        if [ -z "$root_partuuid" ]; then
            echo "Error: could not determine PARTUUID of $root_device"
            return 1
        fi
    fi
    # Strip partition number to get disk (e.g. /dev/sda2 -> /dev/sda)
    disk=$(echo "$root_partition" | sed 's/[0-9]*$//')
    arch-chroot "$INSTALL_POINT" /bin/bash <<EOF
    # Install GRUB and required packages
    print_step "Installing GRUB bootloader for BIOS system..."
    pacman -S --noconfirm grub os-prober
    # Configure GRUB
    if [ "$encryption" = "yes" ]; then
        # Pass the UUID variable into the environment for encrypted systems
        LUKS_UUID="$luks_uuid"
        # Use systemd-based encryption parameter syntax for sd-encrypt hook
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=/dev/mapper/${CRYPTROOT_NAME} rd.luks.name=\$LUKS_UUID=${CRYPTROOT_NAME} ${KERNEL_PARAMS}\"|" /etc/default/grub
        sed -i 's|^#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
        # Add cryptodisk modules to preload
        sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos luks cryptodisk"|' /etc/default/grub
    else
        # For unencrypted systems, use PARTUUID
        ROOT_PARTUUID="$root_partuuid"
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=PARTUUID=\$ROOT_PARTUUID ${KERNEL_PARAMS}\"|" /etc/default/grub
    fi
    # Theme and timing tweaks
    sed -i 's|^#GRUB_TIMEOUT=[0-9]\+|GRUB_TIMEOUT=3|' /etc/default/grub
    sed -i 's|^#GRUB_DISABLE_OS_PROBER=false|GRUB_DISABLE_OS_PROBER=false|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT_STYLE=hidden|#GRUB_TIMEOUT_STYLE=hidden|' /etc/default/grub
    # Install GRUB to MBR
    grub-install \
      --target=i386-pc \
      --recheck \
      --boot-directory=/boot \
      ${disk}
    # Generate GRUB configuration
    grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

configure_luks_trim() {
    if [[ "$encryption" == "yes" && "$ENABLE_LUKS_TRIM" == "yes" ]]; then
        print_step "Configuring LUKS for TRIM/Discard..."
        LUKS_UUID=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$LUKS_UUID" ]; then
            echo "Error: Could not find LUKS UUID for $root_partition"
            return 1
        fi

        # Create crypttab if it doesn't exist
        if [ ! -f "$INSTALL_POINT/etc/crypttab" ]; then
            touch "$INSTALL_POINT/etc/crypttab"
        fi

        # Add entry to crypttab
        echo "$CRYPTROOT_NAME UUID=$LUKS_UUID none discard" >> "$INSTALL_POINT/etc/crypttab"
        echo "LUKS TRIM configured in /etc/crypttab."
    fi
}
