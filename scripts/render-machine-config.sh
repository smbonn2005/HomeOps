#!/usr/bin/env bash
set -Eeuo pipefail

# This script renders and merges Talos machine configurations.
# It uses templates and patches to generate a final configuration for Talos nodes.
#
# Arguments:
# 1. Path to the base Talos machine configuration file.
# 2. Path to the patch file for the machine configuration.
#
# Example Usage:
#   ./render-machine-config.sh controlplane.yaml.j2 nodes/192.168.42.10.yaml.j2
#
# Output:
# The merged Talos configuration is printed to standard output.

source "$(dirname "${0}")/lib/common.sh"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

readonly NODE_BASE="${1:-}" NODE_PATCH="${2:-}"

function cleanup() {
    [[ -n "${TMPFILE:-}" && -f "${TMPFILE}" ]] && rm -f "${TMPFILE}"
}
trap cleanup ERR EXIT

function main() {
    # shellcheck disable=SC2034
    local -r LOG_LEVEL="info"

    check_env KUBERNETES_VERSION TALOS_VERSION
    check_cli minijinja-cli op yq

    if [[ -z "${NODE_BASE}" || -z "${NODE_PATCH}" ]]; then
        log fatal "Both NODE_BASE and NODE_PATCH are required"
    fi

    if ! op user get --me &>/dev/null; then
        log fatal "Failed to authenticate with 1Password CLI"
    fi

    local node_base node_patch machine_config

    node_base=$(render_template "${NODE_BASE}")
    node_patch=$(render_template "${NODE_PATCH}")

    TMPFILE=$(mktemp)
    echo "${node_patch}" > "${TMPFILE}"

    # shellcheck disable=SC2016
    if ! machine_config=$(echo "${node_base}" | yq --exit-status eval-all '. as $item ireduce ({}; . * $item )' - "${TMPFILE}" 2>/dev/null) || [[ -z "${machine_config}" ]]; then
        log fatal "Failed to merge configs"
    fi

    echo "${machine_config}"
}

main "$@"
