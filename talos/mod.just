set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := justfile_dir() + '/talos'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`

[private]
default:
    just -l talos

[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config "{{ node }}" | talosctl -n "{{ node }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos machine image')]
download-image version node="":
    export SCHEMATIC="$(just talos schematic-id "{{ node }}")"; \
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/talos-{{ version }}-${SCHEMATIC:0:8}.iso" \
        "https://factory.talos.dev/image/${SCHEMATIC}/{{ version }}/metal-amd64.iso"; \
    just log info "Downloaded Talos" version "{{ version }}" schematic "${SCHEMATIC}"

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" --default="No" && \
        talosctl -n {{ node }} reboot -m powercycle || exit 0

[doc('Render Talos config for a node')]
render-config node:
    role="controlplane"; \
    if [[ -f "{{ talos_dir }}/nodes/workers/{{ node }}.yaml.j2" ]]; then \
        role="workers"; \
    fi; \
    talosctl machineconfig patch <(just template "{{ talos_dir }}/cluster.yaml.j2" -D "schematic=$(just talos schematic-id "{{ node }}")") \
        -p @<(just template "{{ talos_dir }}/${role}.yaml.j2") \
        -p @<(just template "{{ talos_dir }}/nodes/${role}/{{ node }}.yaml.j2")

[doc('Reset a node')]
reset-node node *args:
    gum confirm "Reset node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false {{ args }} || exit 0

[doc('Shutdown a node')]
shutdown-node node *args:
    gum confirm "Shutdown node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" shutdown --force {{ args }} || exit 0

[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "{{ controller }}" upgrade-k8s --to {{ version }}

[doc('Upgrade Talos version on a node')]
upgrade-node node *args:
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image "{{ node }}")" -m powercycle --timeout=10m {{ args }}

[private]
schematic-file node="":
    file="{{ talos_dir }}/schematic.yaml.j2"; \
    if [[ -n "{{ node }}" ]]; then \
        for f in "{{ talos_dir }}"/nodes/*/"{{ node }}".schematic.yaml.j2; do \
            [[ -f "$f" ]] && file="$f"; \
        done; \
    fi; \
    echo "$file"

[private]
schematic-id node="":
    curl -sX POST --data-binary @<(just template "$(just talos schematic-file "{{ node }}")") "https://factory.talos.dev/schematics" | jq -r '.id'

[private]
machine-image node="":
    just template "{{ talos_dir }}/cluster.yaml.j2" -D "schematic=$(just talos schematic-id "{{ node }}")" | yq -r -e 'select(.kind == "UnattendedInstallConfig") | .installer.image'
