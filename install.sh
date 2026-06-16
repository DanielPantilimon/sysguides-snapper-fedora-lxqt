#!/usr/bin/env bash

# install.sh
# ----------------
# Installs and configures Snapper + grub-btrfs on Fedora
# along with SysGuides Snapper integration scripts.
#
# This script:
# - Installs required packages
# - Configures Snapper (root + home)
# - Sets permissions and ACLs
# - Configures updatedb to ignore snapshots
# - Installs grub-btrfs
# - Installs Snapper integration scripts (DNF5 actions)
#
# Project: sysguides-snapper-fedora
# Original Author: Madhu Desai (SysGuides)
# Website: https://sysguides.com
# GitHub: https://github.com/SysGuides/sysguides-snapper-fedora
# 
# This fork has been Modified with AI to fully configure Snapper on Fedora 44 LXQt
# Apart from the original btrfs partitioning, I have added the /.snapshots partition as part of the installation process
# All credit goes to the Original Author: Madhu Desai (SysGuides)


set -e

# Get absolute path of this script (works regardless of current directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prevent running as root
if [[ $EUID -eq 0 ]]; then
    echo "Please run this script as a normal user:"
    echo "  ./install.sh"
    exit 1
fi

echo "[1/6] Installing required packages..."
sudo dnf install -y snapper libdnf5-plugin-actions btrfs-assistant inotify-tools make git

# Check if system is using Btrfs
if ! findmnt -n -o FSTYPE / | grep -q btrfs; then
    echo "Error: Root filesystem is not Btrfs"
    exit 1
fi

echo "[2/6] Configuring Snapper..."

# --- BULLETPROOF WORKAROUND FOR PRE-EXISTING DEDICATED /.SNAPSHOTS ---
if [ ! -f /etc/snapper/configs/root ]; then
    echo "==> Handling pre-existing /.snapshots mount for Snapper config..."
    
    # 1. Lazily unmount the dedicated partition to clear "Device or resource busy"
    if findmnt / .snapshots > /dev/null; then
        sudo umount -l /.snapshots || true
    fi
    
    # 2. Clear out the empty mount point directory so Snapper has a completely blank slate
    if [ -d /.snapshots ]; then
        sudo rmdir /.snapshots 2>/dev/null || sudo btrfs subvolume delete /.snapshots 2>/dev/null || true
    fi

    # 3. Run snapper configuration (Snapper will create its own folder here)
    sudo snapper -c root create-config /

    # 4. Remove the default folder Snapper just generated to clear the path for your partition
    if [ -d /.snapshots ]; then
        sudo btrfs subvolume delete /.snapshots 2>/dev/null || sudo rmdir /.snapshots 2>/dev/null || true
    fi

    # 5. Re-create a clean, empty mount point folder
    sudo mkdir -p /.snapshots

    # 6. Remount your real, dedicated snapshots partition cleanly from /etc/fstab
    sudo mount /.snapshots
fi

# Create home config if not present
if [ ! -f /etc/snapper/configs/home ]; then
    [ -d /home/.snapshots ] || sudo snapper -c home create-config /home
fi
# ---------------------------------------------------------------------

# Fix SELinux contexts
echo "==> Fixing SELinux contexts..."
sudo restorecon -RFv /.snapshots
sudo restorecon -RFv /home/.snapshots

# Set permissions for current user
echo "==> Setting permissions for current user and Btrfs Assistant..."
REAL_USER=${SUDO_USER:-$USER}
sudo snapper -c root set-config ALLOW_USERS=$REAL_USER SYNC_ACL=yes
sudo snapper -c home set-config ALLOW_USERS=$REAL_USER SYNC_ACL=yes

# Disable timeline snapshots for home
sudo snapper -c home set-config TIMELINE_CREATE=no

# Allow the wheels group (admin) access for Btrfs Assistant integration
sudo chown -R :wheel /.snapshots
sudo chmod 750 /.snapshots

echo "[3/6] Updating locate database config..."

# Ensure .snapshots is excluded from updatedb
if grep -q '^PRUNENAMES' /etc/updatedb.conf; then
    grep -q '\.snapshots' /etc/updatedb.conf || \
    sudo sed -i 's|^PRUNENAMES *= *"|PRUNENAMES = ".snapshots |' /etc/updatedb.conf
else
    echo 'PRUNENAMES = ".snapshots"' | sudo tee -a /etc/updatedb.conf
fi

echo "[4/6] Installing grub-btrfs..."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cd "$tmpdir"

git clone --depth 1 https://github.com/Antynea/grub-btrfs
cd grub-btrfs

# Configure grub-btrfs for Fedora
sed -i \
-e 's|^#GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=.*|GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS="rd.live.overlay.overlayfs=1"|' \
-e 's|^#GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/boot/grub2"|' \
-e 's|^#GRUB_BTRFS_MKCONFIG=.*|GRUB_BTRFS_MKCONFIG=/usr/bin/grub2-mkconfig|' \
-e 's|^#GRUB_BTRFS_SCRIPT_CHECK=.*|GRUB_BTRFS_SCRIPT_CHECK=grub2-script-check|' \
config

sudo make install
sudo systemctl enable --now grub-btrfsd.service

# Generate GRUB config (important for first run)
echo "==> Updating GRUB configuration..."
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

echo "[5/6] Installing Snapper integration scripts..."

# Install scripts
sudo install -m 755 "$SCRIPT_DIR"/scripts/* /usr/local/bin/

# Restore SELinux context
sudo restorecon -v /usr/local/bin/snapper-*.sh

# Install DNF5 actions file
sudo mkdir -p /etc/dnf/libdnf5-plugins/actions.d/
sudo install -m 644 "$SCRIPT_DIR"/config/snapper.actions /etc/dnf/libdnf5-plugins/actions.d/

echo "[6/6] Enabling Snapper timers..."

sudo systemctl enable --now snapper-timeline.timer
sudo systemctl enable --now snapper-cleanup.timer

echo ""
echo "✅ Installation complete!"
echo "Snapper is now fully integrated with DNF5 CLI"
echo "Open Btrfs Assistant from your LXQt applications menu to manage your layout visually!"

