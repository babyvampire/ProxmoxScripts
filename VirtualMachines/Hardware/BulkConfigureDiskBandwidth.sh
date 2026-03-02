#!/bin/bash
#
# BulkConfigureDiskBandwidth.sh
#
# Configures per-disk bandwidth (MB/s) throttle limits for a range of virtual machines (VMs)
# on a Proxmox VE cluster. Supports read limit, write limit, read max burst, and write max burst.
# Automatically detects which node each VM is on and executes the operation cluster-wide.
#
# Usage:
#   BulkConfigureDiskBandwidth.sh 100 110 --mbps-rd 100
#   BulkConfigureDiskBandwidth.sh 100 110 --mbps-rd 100 --mbps-wr 50
#   BulkConfigureDiskBandwidth.sh 100 110 --mbps-rd 200 --mbps-wr 100 --mbps-rd-max 400 --mbps-wr-max 200
#   BulkConfigureDiskBandwidth.sh 100 110 --mbps-rd 100 --disk-id virtio0
#   BulkConfigureDiskBandwidth.sh 400 410 --mbps-rd 0 --mbps-wr 0 --mbps-rd-max 0 --mbps-wr-max 0
#   BulkConfigureDiskBandwidth.sh 100 110 --mbps-rd 100 --mbps-wr 50 --all-disks
#
# Arguments:
#   start_id               - Starting VM ID in the range
#   end_id                 - Ending VM ID in the range
#   --mbps-rd <num>        - Read bandwidth limit in MB/s (0=unlimited)
#   --mbps-wr <num>        - Write bandwidth limit in MB/s (0=unlimited)
#   --mbps-rd-max <num>    - Read burst bandwidth limit in MB/s (0=unlimited)
#   --mbps-wr-max <num>    - Write burst bandwidth limit in MB/s (0=unlimited)
#   --disk-id <id>         - Disk interface ID (default: scsi0, ignored with --all-disks)
#   --all-disks            - Apply limits to all disks attached to each VM
#
# Disk IDs: scsi0, scsi1, virtio0, virtio1, ide0, ide2, sata0, sata1, etc.
#
# Notes:
#   - At least one bandwidth option must be specified
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
# @description Validates bandwidth-specific configuration options not covered by ArgumentParser.
validate_custom_options() {
    # Check that at least one bandwidth option is specified
    if [[ -z "$MBPS_RD" && -z "$MBPS_WR" && -z "$MBPS_RD_MAX" && -z "$MBPS_WR_MAX" ]]; then
        __err__ "At least one bandwidth option must be specified"
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
    if [[ -n "$MBPS_RD" && -n "$MBPS_RD_MAX" && "$MBPS_RD" != "0" && "$MBPS_RD_MAX" != "0" ]]; then
        if (( $(echo "$MBPS_RD_MAX < $MBPS_RD" | bc -l) )); then
            __warn__ "Read burst (${MBPS_RD_MAX} MB/s) is less than read limit (${MBPS_RD} MB/s)"
        fi
    fi

    if [[ -n "$MBPS_WR" && -n "$MBPS_WR_MAX" && "$MBPS_WR" != "0" && "$MBPS_WR_MAX" != "0" ]]; then
        if (( $(echo "$MBPS_WR_MAX < $MBPS_WR" | bc -l) )); then
            __warn__ "Write burst (${MBPS_WR_MAX} MB/s) is less than write limit (${MBPS_WR} MB/s)"
        fi
    fi
}

# --- main --------------------------------------------------------------------
main() {
    __check_root__
    __check_proxmox__

    # Parse arguments using ArgumentParser
    __parse_args__ "start_id:vmid end_id:vmid --mbps-rd:number:? --mbps-wr:number:? --mbps-rd-max:number:? --mbps-wr-max:number:? --disk-id:string:scsi0 --all-disks:flag" "$@"

    # Additional custom validation
    validate_custom_options

    __info__ "Bulk configure disk bandwidth: VMs ${START_ID} to ${END_ID} (cluster-wide)"
    if [[ "$ALL_DISKS" == "true" ]]; then
        __info__ "Target: all disks on each VM"
    else
        __info__ "Disk interface: ${DISK_ID}"
    fi
    [[ -n "$MBPS_RD" ]] && __info__ "  Read limit: ${MBPS_RD} MB/s"
    [[ -n "$MBPS_WR" ]] && __info__ "  Write limit: ${MBPS_WR} MB/s"
    [[ -n "$MBPS_RD_MAX" ]] && __info__ "  Read burst: ${MBPS_RD_MAX} MB/s"
    [[ -n "$MBPS_WR_MAX" ]] && __info__ "  Write burst: ${MBPS_WR_MAX} MB/s"

    # Confirm action
    if ! __prompt_user_yn__ "Configure disk bandwidth for VMs ${START_ID}-${END_ID}?"; then
        __info__ "Operation cancelled by user"
        exit 0
    fi

    # Local callback for bulk operation
    configure_bandwidth_callback() {
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

            # Update read bandwidth limit
            if [[ -n "$MBPS_RD" ]]; then
                new_config=$(echo "$new_config" | sed -e "s/,mbps_rd=[^,]*//" -e "s/mbps_rd=[^,]*,//")
                [[ "$MBPS_RD" != "0" ]] && new_config="${new_config},mbps_rd=${MBPS_RD}"
            fi

            # Update write bandwidth limit
            if [[ -n "$MBPS_WR" ]]; then
                new_config=$(echo "$new_config" | sed -e "s/,mbps_wr=[^,]*//" -e "s/mbps_wr=[^,]*,//")
                [[ "$MBPS_WR" != "0" ]] && new_config="${new_config},mbps_wr=${MBPS_WR}"
            fi

            # Update read burst bandwidth limit
            if [[ -n "$MBPS_RD_MAX" ]]; then
                new_config=$(echo "$new_config" | sed -e "s/,mbps_rd_max=[^,]*//" -e "s/mbps_rd_max=[^,]*,//")
                [[ "$MBPS_RD_MAX" != "0" ]] && new_config="${new_config},mbps_rd_max=${MBPS_RD_MAX}"
            fi

            # Update write burst bandwidth limit
            if [[ -n "$MBPS_WR_MAX" ]]; then
                new_config=$(echo "$new_config" | sed -e "s/,mbps_wr_max=[^,]*//" -e "s/mbps_wr_max=[^,]*,//")
                [[ "$MBPS_WR_MAX" != "0" ]] && new_config="${new_config},mbps_wr_max=${MBPS_WR_MAX}"
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
    __bulk_vm_operation__ --name "Disk Bandwidth Configuration" --report "$START_ID" "$END_ID" configure_bandwidth_callback

    # Display summary
    __bulk_summary__

    [[ $BULK_FAILED -gt 0 ]] && exit 1
    __ok__ "All disk bandwidth configurations completed successfully!"
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
