#!/bin/bash
#
# BulkAddToPool.sh
#
# Adds LXC containers to a Proxmox VE resource pool.
# Uses BulkOperations framework for cluster-wide execution.
#
# Usage:
#   BulkAddToPool.sh <start_ctid> <end_ctid> <pool>
#
# Arguments:
#   start_ctid - Starting container ID
#   end_ctid   - Ending container ID
#   pool       - Target resource pool name
#
# Examples:
#   BulkAddToPool.sh 200 230 production
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
__parse_args__ "start_ctid:ctid end_ctid:ctid pool:pool" "$@"

# --- main --------------------------------------------------------------------
main() {
    __check_root__
    __check_proxmox__

    add_to_pool_callback() {
        local ctid="$1"
        pvesh set "/pools/${POOL}" --vms "$ctid"
    }

    __bulk_ct_operation__ --name "Add Containers to Pool (${POOL})" --report "$START_CTID" "$END_CTID" add_to_pool_callback

    __bulk_summary__

    [[ $BULK_FAILED -gt 0 ]] && exit 1
    __ok__ "Containers added to pool '${POOL}' successfully!"
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
