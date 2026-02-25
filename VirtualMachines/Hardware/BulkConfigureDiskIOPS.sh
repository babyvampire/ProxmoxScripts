#!/bin/bash
#
# BulkConfigureDiskIOPS.sh
#
# Configures per-disk IOPS (I/O operations per second) throttle limits for a range of virtual
# machines (VMs) on a Proxmox VE cluster. Supports read limit, write limit, read max burst,
# and write max burst.
# Automatically detects which node each VM is on and executes the operation cluster-wide.
#
# Usage:
#   BulkConfigureDiskIOPS.sh 100 110 --iops-rd 1000
#   BulkConfigureDiskIOPS.sh 100 110 --iops-rd 1000 --iops-wr 500
#   BulkConfigureDiskIOPS.sh 100 110 --iops-rd 2000 --iops-wr 1000 --iops-rd-max 4000 --iops-wr-max 2000
#   BulkConfigureDiskIOPS.sh 100 110 --iops-rd 1000 --disk-id virtio0
#   BulkConfigureDiskIOPS.sh 400 410 --iops-rd 0 --iops-wr 0 --iops-rd-max 0 --iops-wr-max 0
#   BulkConfigureDiskIOPS.sh 100 110 --iops-rd 1000 --iops-wr 500 --all-disks
#
# Arguments:
#   start_id               - Starting VM ID in the range
#   end_id                 - Ending VM ID in the range
#   --iops-rd <num>        - Read IOPS limit (0=unlimited)
#   --iops-wr <num>        - Write IOPS limit (0=unlimited)
#   --iops-rd-max <num>    - Read burst IOPS limit (0=unlimited)
#   --iops-wr-max <num>    - Write burst IOPS limit (0=unlimited)
#   --disk-id <id>         - Disk interface ID (default: scsi0, ignored with --all-disks)
#   --all-disks            - Apply limits to all disks attached to each VM
#
# Disk IDs: scsi0, scsi1, virtio0, virtio1, ide0, ide2, sata0, sata1, etc.
#
# Notes:
#   - At least one IOPS option must be specified
#   - Set a value to 0 to remove that limit
#   - Burst limits (max) should be >= base limits when both are set
#   - Changes take effect immediately for running VMs (no reboot required)
#
# Function Index:
#   - validate_custom_options
#   - main
#

set -euo pipefail

# shellcheck source=Utilities/ArgumentParser.sh
source "${UTILITYPATH}/ArgumentParser.sh"
# shellcheck source=Utilities/Prompts.sh
source "${UTILITYPATH}/Prompts.sh"
# shellcheck source=Utilities/Communication.sh
source "${UTILITYPATH}/Communication.sh"
# shellcheck source=Utilities/BulkOperations.sh
source "${UTILITYPATH}/BulkOperations.sh"
# shellcheck source=Utilities/Cluster.sh
source "${UTILITYPATH}/Cluster.sh"
# shellcheck source=Utilities/Operations.sh
source "${UTILITYPATH}/Operations.sh"

trap '__handle_err__ $LINENO "$BASH_COMMAND"' ERR

# --- validate_custom_options -------------------------------------------------
# @function validate_custom_options
# @description Validates IOPS-specific configuration options not covered by ArgumentParser.
validate_custom_options() {
    # Check that at least one IOPS option is specified
    if [[ -z "$IOPS_RD" && -z "$IOPS_WR" && -z "$IOPS_RD_MAX" && -z "$IOPS_WR_MAX" ]]; then
        __err__ "At least one IOPS option must be specified"
        exit 64
    fi

    # Validate disk ID format
    if [[ -n "$DISK_ID" ]]; then
        if ! [[ "$DISK_ID" =~ ^(scsi|virtio|ide|sata)[0-9]+$ ]]; then
            __err__ "Invalid disk ID format: ${DISK_ID}"
            __err__ "Valid formats: scsi0, virtio0, ide0, sata0, etc."
            exit 64
        fi
    fi

    # Warn if burst is less than base limit
    if [[ -n "$IOPS_RD" && -n "$IOPS_RD_MAX" && "$IOPS_RD" != "0" && "$IOPS_RD_MAX" != "0" ]]; then
        if (( IOPS_RD_MAX < IOPS_RD )); then
            __warn__ "Read burst (${IOPS_RD_MAX} IOPS) is less than read limit (${IOPS_RD} IOPS)"
        fi
    fi

    if [[ -n "$IOPS_WR" && -n "$IOPS_WR_MAX" && "$IOPS_WR" != "0" && "$IOPS_WR_MAX" != "0" ]]; then
        if (( IOPS_WR_MAX < IOPS_WR )); then
            __warn__ "Write burst (${IOPS_WR_MAX} IOPS) is less than write limit (${IOPS_WR} IOPS)"
        fi
    fi
}

# --- main --------------------------------------------------------------------
main() {
    __check_root__
    __check_proxmox__

    # Parse arguments using ArgumentParser
    __parse_args__ "start_id:vmid end_id:vmid --iops-rd:number:? --iops-wr:number:? --iops-rd-max:number:? --iops-wr-max:number:? --disk-id:string:scsi0 --all-disks:flag" "$@"

    # Additional custom validation
    validate_custom_options

    __info__ "Bulk configure disk IOPS: VMs ${START_ID} to ${END_ID} (cluster-wide)"
    if [[ "$ALL_DISKS" == "true" ]]; then
        __info__ "Target: all disks on each VM"
    else
        __info__ "Disk interface: ${DISK_ID}"
    fi
    [[ -n "$IOPS_RD" ]] && __info__ "  Read limit: ${IOPS_RD} IOPS"
    [[ -n "$IOPS_WR" ]] && __info__ "  Write limit: ${IOPS_WR} IOPS"
    [[ -n "$IOPS_RD_MAX" ]] && __info__ "  Read burst: ${IOPS_RD_MAX} IOPS"
    [[ -n "$IOPS_WR_MAX" ]] && __info__ "  Write burst: ${IOPS_WR_MAX} IOPS"

    # Confirm action
    if ! __prompt_user_yn__ "Configure disk IOPS for VMs ${START_ID}-${END_ID}?"; then
        __info__ "Operation cancelled by user"
        exit 0
    fi

    # Local callback for bulk operation
    configure_iops_callback() {
        local vmid="$1"
        local node

        node=$(__get_vm_node__ "$vmid")

        if [[ -z "$node" ]]; then
            __update__ "VM ${vmid} not found in cluster"
            return 1
        fi

        # Determine which disks to configure
        local disk_list
        if [[ "$ALL_DISKS" == "true" ]]; then
            disk_list=$(__node_exec__ "$node" "qm config ${vmid}" 2>/dev/null | grep -E "^(scsi|virtio|ide|sata)[0-9]+:" | cut -d':' -f1 || echo "")
            if [[ -z "$disk_list" ]]; then
                __update__ "VM ${vmid} has no disks"
                return 1
            fi
        else
            disk_list="$DISK_ID"
        fi

        local disk_failed=0
        local disk_count=0

        while IFS= read -r current_disk; do
            [[ -z "$current_disk" ]] && continue
            disk_count=$((disk_count + 1))

            __update__ "Configuring ${current_disk} on VM ${vmid} (node ${node})..."

            # Get current disk configuration
            local current_config
            current_config=$(__node_exec__ "$node" "qm config ${vmid}" 2>/dev/null | grep "^${current_disk}:" | cut -d' ' -f2- || echo "")

            if [[ -z "$current_config" ]]; then
                __update__ "VM ${vmid} has no ${current_disk} disk"
                disk_failed=$((disk_failed + 1))
                continue
            fi

            # Build new configuration by modifying existing config
            local new_config="$current_config"

            # Update read IOPS limit
            if [[ -n "$IOPS_RD" ]]; then
                new_config=$(echo "$new_config" | sed "s/,iops_rd=[^,]*//" | sed "s/iops_rd=[^,]*,//")
                [[ "$IOPS_RD" != "0" ]] && new_config="${new_config},iops_rd=${IOPS_RD}"
            fi

            # Update write IOPS limit
            if [[ -n "$IOPS_WR" ]]; then
                new_config=$(echo "$new_config" | sed "s/,iops_wr=[^,]*//" | sed "s/iops_wr=[^,]*,//")
                [[ "$IOPS_WR" != "0" ]] && new_config="${new_config},iops_wr=${IOPS_WR}"
            fi

            # Update read burst IOPS limit
            if [[ -n "$IOPS_RD_MAX" ]]; then
                new_config=$(echo "$new_config" | sed "s/,iops_rd_max=[^,]*//" | sed "s/iops_rd_max=[^,]*,//")
                [[ "$IOPS_RD_MAX" != "0" ]] && new_config="${new_config},iops_rd_max=${IOPS_RD_MAX}"
            fi

            # Update write burst IOPS limit
            if [[ -n "$IOPS_WR_MAX" ]]; then
                new_config=$(echo "$new_config" | sed "s/,iops_wr_max=[^,]*//" | sed "s/iops_wr_max=[^,]*,//")
                [[ "$IOPS_WR_MAX" != "0" ]] && new_config="${new_config},iops_wr_max=${IOPS_WR_MAX}"
            fi

            # Apply configuration on correct node
            if ! __node_exec__ "$node" "qm set ${vmid} --${current_disk} '${new_config}'" 2>&1; then
                disk_failed=$((disk_failed + 1))
            fi
        done <<< "$disk_list"

        if [[ $disk_failed -gt 0 ]]; then
            __update__ "VM ${vmid}: ${disk_failed}/${disk_count} disk(s) failed"
            return 1
        fi

        return 0
    }

    # Use BulkOperations framework
    __bulk_vm_operation__ --name "Disk IOPS Configuration" --report "$START_ID" "$END_ID" configure_iops_callback

    # Display summary
    __bulk_summary__

    [[ $BULK_FAILED -gt 0 ]] && exit 1
    __ok__ "All disk IOPS configurations completed successfully!"
}

main "$@"

###############################################################################
# Script notes:
###############################################################################
# Last checked: 2026-02-20
#
# Changes:
# - 2026-02-20: Initial version
#
# Fixes:
# -
#
# Known issues:
# -
#
