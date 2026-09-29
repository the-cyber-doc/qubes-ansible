#!/bin/bash
# reset-vm-resources.sh
# Run in dom0. Resets vcpus, maxmem, and memory to their defaults
# for every VM, skipping running VMs and VMs with PCI passthrough.

set -uo pipefail

DRY_RUN=0
INCLUDE_PCI=0
INCLUDE_SPECIAL=0
PROPS=(vcpus maxmem memory)

usage() {
    cat <<EOF
Usage: $0 [-n] [-p] [-s]
  -n   dry run; show what would be done, change nothing
  -p   include VMs with PCI devices attached (DANGEROUS for sys-net/sys-usb/GPU-passthrough VMs)
  -s   include sys-* VMs (excluded by default as a safety measure)
  -h   show this help

Resets vcpus, maxmem, and memory to their qvm-prefs defaults for every VM.
Running VMs are skipped (must be halted to change these properties).
EOF
}

while getopts "npsh" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        p) INCLUDE_PCI=1 ;;
        s) INCLUDE_SPECIAL=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Collect all VMs except dom0
mapfile -t VMS < <(qvm-ls --raw-list | grep -v '^dom0$')

processed=()
skipped_running=()
skipped_pci=()
skipped_special=()
failed=()

for vm in "${VMS[@]}"; do
    # Skip running/paused VMs — these properties can't be changed live
    if qvm-check --running "$vm" 2>/dev/null; then
        skipped_running+=("$vm")
        continue
    fi

    # Skip sys-* VMs by default (they often have hand-tuned resources)
    if [[ $INCLUDE_SPECIAL -eq 0 && "$vm" == sys-* ]]; then
        skipped_special+=("$vm")
        continue
    fi

    # Skip VMs with PCI devices unless -p
    if [[ $INCLUDE_PCI -eq 0 ]] && [[ -n "$(qvm-pci ls "$vm" 2>/dev/null)" ]]; then
        skipped_pci+=("$vm")
        continue
    fi

    echo "=== $vm ==="
    vm_failed=0
    for prop in "${PROPS[@]}"; do
        if [[ $DRY_RUN -eq 1 ]]; then
            current=$(qvm-prefs "$vm" "$prop" 2>/dev/null || echo "?")
            printf "  [dry-run] %-8s currently=%s → would reset to default\n" "$prop" "$current"
        else
            if qvm-prefs -D "$vm" "$prop"; then
                new=$(qvm-prefs "$vm" "$prop" 2>/dev/null || echo "?")
                printf "  reset %-8s → %s\n" "$prop" "$new"
            else
                printf "  FAILED to reset %s\n" "$prop"
                vm_failed=1
            fi
        fi
    done

    if [[ $vm_failed -eq 1 ]]; then
        failed+=("$vm")
    else
        processed+=("$vm")
    fi
done

echo
echo "==== Summary ===="
echo "Processed:        ${#processed[@]} ${processed[*]:-}"
echo "Skipped running:  ${#skipped_running[@]} ${skipped_running[*]:-}"
echo "Skipped sys-*:    ${#skipped_special[@]} ${skipped_special[*]:-}"
echo "Skipped PCI:      ${#skipped_pci[@]} ${skipped_pci[*]:-}"
echo "Failed:           ${#failed[@]} ${failed[*]:-}"
