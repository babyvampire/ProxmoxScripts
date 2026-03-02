#!/bin/bash
#
# BulkAddToPool.sh
#
# Adds virtual machines to a Proxmox VE resource pool.
# Uses BulkOperations framework for cluster-wide execution.
#
# Usage:
#   BulkAddToPool.sh <start_vmid> <end_vmid> <pool>
#
# Arguments:
#   start_vmid - Starting VM ID
#   end_vmid   - Ending VM ID
#   pool       - Target resource pool name
#
# Examples:
#   BulkAddToPool.sh 400 430 production
#   BulkAddToPool.sh 100 100 testing
#
# Function Index:
#   - main
#

set -euo pipefail

# shellcheck source=Utilities/Prompts.sh
source "${UTILITYPATH}/Prompts.sh"
# shellcheck source=Utilities/Communication.sh
source "${UTILITYPATH}/Communication.sh"
# shellcheck source=Utilities/ArgumentParser.sh
source "${UTILITYPATH}/ArgumentParser.sh"
# shellcheck source=Utilities/BulkOperations.sh
source "${UTILITYPATH}/BulkOperations.sh"

trap '__handle_err__ $LINENO "$BASH_COMMAND"' ERR

# Parse arguments
__parse_args__ "start_vmid:vmid end_vmid:vmid pool:pool" "$@"

# --- main --------------------------------------------------------------------
main() {
    __check_root__
    __check_proxmox__

    add_to_pool_callback() {
        local vmid="$1"
        pvesh set "/pools/${POOL}" --vms "$vmid"
    }

    __bulk_vm_operation__ --name "Add VMs to Pool (${POOL})" --report "$START_VMID" "$END_VMID" add_to_pool_callback

    __bulk_summary__

    [[ $BULK_FAILED -gt 0 ]] && exit 1
    __ok__ "VMs added to pool '${POOL}' successfully!"
}

main

###############################################################################
# Script notes:
###############################################################################
# Last checked: 2026-02-27
#
# Changes:
# - 2026-02-27: Initial creation
#
# Fixes:
# -
#
# Known issues:
# -
#
