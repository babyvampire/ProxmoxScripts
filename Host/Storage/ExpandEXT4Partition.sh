#!/bin/bash
#
# ExpandEXT4Partition.sh
#
# Expands a GPT partition and ext4 filesystem to use available disk space.
# Uses sgdisk to recreate the partition non-interactively (preserving start
# sector, UUID, type and name) so the operation works on mounted filesystems
# without unmounting.
#
# Usage:
#   ExpandEXT4Partition.sh <device>
#
# Arguments:
#   device - Disk device (e.g., /dev/sdb)
#
# Examples:
#   ExpandEXT4Partition.sh /dev/sdb
#
# Function Index:
#   - main
#

set -euo pipefail

# shellcheck source=Utilities/ArgumentParser.sh
source "${UTILITYPATH}/ArgumentParser.sh"
# shellcheck source=Utilities/Prompts.sh
source "${UTILITYPATH}/Prompts.sh"
# shellcheck source=Utilities/Communication.sh
source "${UTILITYPATH}/Communication.sh"

trap '__handle_err__ $LINENO "$BASH_COMMAND"' ERR

__parse_args__ "device:path" "$@"

# Verify block device
if [[ ! -b "$DEVICE" ]]; then
    __err__ "Not a valid block device: $DEVICE"
    exit 1
fi

# --- main --------------------------------------------------------------------
main() {
    __check_root__
    __check_proxmox__

    __install_or_prompt__ "gdisk"
    __install_or_prompt__ "util-linux"
    __install_or_prompt__ "e2fsprogs"

    # Construct partition device name (handle nvme/mmcblk naming)
    local partition
    if [[ "$DEVICE" =~ (nvme|mmcblk|loop) ]]; then
        partition="${DEVICE}p1"
    else
        partition="${DEVICE}1"
    fi

    __warn__ "This will resize partition ${partition} to use all available space"
    __warn__ "Ensure you have backups before proceeding"

    if ! __prompt_user_yn__ "Proceed with partition expansion?"; then
        __info__ "Operation cancelled"
        exit 0
    fi

    # Fix GPT if needed (relocate secondary header to end of disk).
    # When partitions on the device are mounted, partprobe cannot re-read the
    # in-kernel partition table; refresh per-partition state with partx -u so
    # parted sees a consistent view on the next invocation.
    __info__ "Fixing GPT table if needed"
    sgdisk -e "$DEVICE" 2>&1 || true
    partprobe "$DEVICE" 2>&1 || partx -u "$DEVICE" 2>&1 || true
    sleep 2

    # Verify exactly one partition exists
    local part_count
    part_count=$(lsblk -no NAME "$DEVICE" | grep -c "[0-9]$" || echo 0)
    if [[ "$part_count" -ne 1 ]]; then
        __err__ "Expected exactly 1 partition on device, found $part_count"
        __err__ "This script only supports single-partition devices"
        exit 1
    fi

    # Detect mount state - prefer online resize so we don't have to unmount
    local mountpoint
    mountpoint=$(lsblk -no MOUNTPOINT "$partition" 2>/dev/null | head -n1 || true)
    local was_mounted=0
    local online_resize=0
    if [[ -n "$mountpoint" ]]; then
        was_mounted=1
        __info__ "${partition} is mounted at ${mountpoint}"
        __info__ "Attempting online expansion (no unmount required)"
        online_resize=1
    fi

    # Capture pre-resize partition size so we can verify the resize actually
    # changed something
    local size_before
    size_before=$(blockdev --getsize64 "$partition" 2>/dev/null || echo 0)

    # Resize partition non-interactively using sgdisk. parted's interactive
    # heredoc approach is brittle: the "Fix/Ignore?" GPT-recovery prompt and
    # the "partition in use" Yes/No prompt both consume our input lines and
    # cause "invalid token" errors. sgdisk has no prompts and works fine on
    # mounted devices because it only writes the on-disk GPT - the kernel
    # picks up the change later via partx -u.
    #
    # Read the current partition's first sector, type code, and
    # unique GUID, then delete partition 1 and recreate it at the same start
    # spanning to the end of the disk (0 = end). This is what
    # `parted resizepart 1 100%` does, just without the prompts.
    __info__ "Resizing partition to use all available space (sgdisk)"

    local part_info first_sector part_type part_uuid part_name
    part_info=$(sgdisk -i 1 "$DEVICE" 2>&1) || {
        __err__ "Failed to read partition 1 info"
        echo "$part_info"
        exit 1
    }

    first_sector=$(echo "$part_info" | awk -F': ' '/First sector/ {print $2}' | awk '{print $1}')
    part_type=$(echo "$part_info"   | awk -F': ' '/Partition GUID code/ {print $2}' | awk '{print $1}')
    part_uuid=$(echo "$part_info"   | awk -F': ' '/Partition unique GUID/ {print $2}' | awk '{print $1}')
    part_name=$(echo "$part_info"   | awk -F"'" '/Partition name/ {print $2}')

    if [[ -z "$first_sector" || -z "$part_type" || -z "$part_uuid" ]]; then
        __err__ "Could not parse partition metadata from sgdisk:"
        echo "$part_info"
        exit 1
    fi

    __info__ "Recreating partition 1 (start=${first_sector}, type=${part_type}, uuid=${part_uuid})"

    local sgdisk_args=(
        -d 1
        -n "1:${first_sector}:0"
        -t "1:${part_type}"
        -u "1:${part_uuid}"
    )
    if [[ -n "$part_name" ]]; then
        sgdisk_args+=( -c "1:${part_name}" )
    fi

    local sgdisk_out
    if ! sgdisk_out=$(sgdisk "${sgdisk_args[@]}" "$DEVICE" 2>&1); then
        __err__ "sgdisk failed to recreate partition:"
        echo "$sgdisk_out"
        exit 1
    fi
    __ok__ "Partition table updated on disk"

    # Inform the kernel of the new partition size. partprobe will fail to
    # re-read the table while a partition is mounted, so fall back to
    # partx --update which can update a single partition online
    if [[ "$was_mounted" -eq 1 ]]; then
        __info__ "Updating kernel partition table online (partx)"
        partx -u "$partition" 2>&1 || partx -u "$DEVICE" 2>&1 || true
    else
        partprobe "$DEVICE" 2>&1 || true
    fi
    sleep 2

    # Verify the kernel sees the new (larger) partition size.
    local size_after
    size_after=$(blockdev --getsize64 "$partition" 2>/dev/null || echo 0)
    if [[ "$size_after" -le "$size_before" ]]; then
        __err__ "Partition size did not increase (before=${size_before} after=${size_after})"
        __err__ "sgdisk output:"
        echo "$sgdisk_out"
        exit 1
    fi
    __ok__ "Kernel sees new partition size: ${size_after} bytes (was ${size_before})"

    # e2fsck cannot run on a mounted filesystem; skip when online.
    if [[ "$online_resize" -eq 0 ]]; then
        __info__ "Checking filesystem"
        if e2fsck -f -y "$partition" 2>&1; then
            __ok__ "Filesystem check completed"
        else
            __warn__ "Filesystem check reported issues"
        fi
    else
        __info__ "Skipping e2fsck (filesystem is mounted)"
    fi

    # Resize the ext4 filesystem. resize2fs supports online growth on
    # mounted ext4 filesystems.
    __info__ "Resizing ext4 filesystem"
    if resize2fs "$partition" 2>&1; then
        __ok__ "Filesystem resized"
    else
        __err__ "Failed to resize filesystem"
        exit 1
    fi

    echo
    __ok__ "Partition expansion completed successfully!"
    __info__ "Verify with: lsblk or df -h"

    __prompt_keep_installed_packages__
}

main "$@"

###############################################################################
# Script notes:
###############################################################################
# Last checked: 2026-04-29
#
# Changes:
# - 2026-04-29: Switched from parted heredoc to sgdisk for non-interactive
#   resize - parted's Fix/Ignore + in-use Yes/No prompts could not be
#   answered reliably and left the partition unchanged
# - 2026-04-29: Online expansion - no unmount required for mounted ext4
# - 2026-04-29: Verify kernel sees new partition size before resize2fs
# - 2025-11-20: Updated to use utility functions
# - 2025-11-20: Updated to use ArgumentParser.sh
# - 2025-11-20: Added proper nvme/mmcblk partition naming support
# - 2025-11-20: Validated against CONTRIBUTING.md
#
# Fixes:
# - 2026-04-29: FIXED: parted heredoc sent "Yes" to a Fix/Ignore prompt,
#   causing "invalid token" errors and leaving the partition at its original
#   size while the script reported success. Replaced with sgdisk delete +
#   recreate at the same start sector preserving GUID/type/name, and added a
#   blockdev size verification step before calling resize2fs.
# - 2026-04-29: FIXED: umount failed when the partition was in use
#   (e.g. /mnt/pve/storage). Online resize is now the default path.
# - 2025-11-20: Fixed partition count logic (was counting device + partitions)
#
# Known issues:
# -
#

