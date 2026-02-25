#!/bin/bash
#
# BulkConfigureNetworkBandwidth.sh
#
# Configures network bandwidth rate limits on all network interfaces for a range of virtual
# machines (VMs) on a Proxmox VE cluster. Applies the rate limit to every network card (net0,
# net1, etc.) attached to each VM.
# Automatically detects which node each VM is on and executes the operation cluster-wide.
#
# Usage:
#   BulkConfigureNetworkBandwidth.sh 100 110 --rate 100
#   BulkConfigureNetworkBandwidth.sh 100 110 --rate 1000
#   BulkConfigureNetworkBandwidth.sh 400 410 --rate 0
#
# Arguments:
#   start_id           - Starting VM ID in the range
#   end_id             - Ending VM ID in the range
#   --rate <mbps>      - Rate limit in MB/s (0=unlimited)
#
# Notes:
#   - Applies the rate limit to ALL network interfaces on each VM
#   - Set rate to 0 to remove the bandwidth limit
#   - Changes take effect immediately for running VMs (no reboot required)
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
# shellcheck source=Utilities/BulkOperations.sh
source "${UTILITYPATH}/BulkOperations.sh"
# shellcheck source=Utilities/Cluster.sh
source "${UTILITYPATH}/Cluster.sh"
# shellcheck source=Utilities/Operations.sh
source "${UTILITYPATH}/Operations.sh"

trap '__handle_err__ $LINENO "$BASH_COMMAND"' ERR

# --- main --------------------------------------------------------------------
main() {
    __check_root__
    __check_proxmox__

    # Parse arguments using ArgumentParser
    __parse_args__ "start_id:vmid end_id:vmid --rate:number" "$@"

    __info__ "Bulk configure network bandwidth: VMs ${START_ID} to ${END_ID} (cluster-wide)"
    if [[ "$RATE" == "0" ]]; then
        __info__ "  Rate limit: unlimited (removing limit)"
    else
        __info__ "  Rate limit: ${RATE} MB/s"
    fi

    # Confirm action
    if ! __prompt_user_yn__ "Configure network bandwidth for VMs ${START_ID}-${END_ID}?"; then
        __info__ "Operation cancelled by user"
        exit 0
    fi

    # Local callback for bulk operation
    configure_net_bandwidth_callback() {
        local vmid="$1"
        local node

        node=$(__get_vm_node__ "$vmid")

        if [[ -z "$node" ]]; then
            __update__ "VM ${vmid} not found in cluster"
            return 1
        fi

        # Get all network interfaces for this VM
        local net_ids
        net_ids=$(__node_exec__ "$node" "qm config ${vmid}" 2>/dev/null | grep "^net[0-9]*:" | cut -d':' -f1 || echo "")

        if [[ -z "$net_ids" ]]; then
            __update__ "VM ${vmid} has no network interfaces"
            return 1
        fi

        local net_count=0
        local net_failed=0

        while IFS= read -r net_id; do
            [[ -z "$net_id" ]] && continue
            net_count=$((net_count + 1))

            __update__ "Configuring ${net_id} on VM ${vmid} (node ${node})..."

            # Get current config for this interface
            local current_config
            current_config=$(__node_exec__ "$node" "qm config ${vmid}" 2>/dev/null | grep "^${net_id}:" | cut -d' ' -f2- || echo "")

            if [[ -z "$current_config" ]]; then
                net_failed=$((net_failed + 1))
                continue
            fi

            # Update rate in existing config
            local new_config="$current_config"

            # Remove existing rate parameter
            new_config=$(echo "$new_config" | sed "s/,rate=[^,]*//" | sed "s/rate=[^,]*,//")

            # Add new rate if non-zero
            [[ "$RATE" != "0" ]] && new_config="${new_config},rate=${RATE}"

            # Apply configuration on correct node
            if ! __node_exec__ "$node" "qm set ${vmid} --${net_id} '${new_config}'" 2>&1; then
                net_failed=$((net_failed + 1))
            fi
        done <<< "$net_ids"

        if [[ $net_failed -gt 0 ]]; then
            __update__ "VM ${vmid}: ${net_failed}/${net_count} interfaces failed"
            return 1
        fi

        __update__ "VM ${vmid}: configured ${net_count} interface(s)"
        return 0
    }

    # Use BulkOperations framework
    __bulk_vm_operation__ --name "Network Bandwidth Configuration" --report "$START_ID" "$END_ID" configure_net_bandwidth_callback

    # Display summary
    __bulk_summary__

    [[ $BULK_FAILED -gt 0 ]] && exit 1
    __ok__ "All network bandwidth configurations completed successfully!"
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
