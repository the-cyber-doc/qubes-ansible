#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_PREFIX="qubes-ansible"
TMP_DIR="/tmp"

for cmd in tar 7z; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done

decompress() {
    mapfile -t archives < <(find "${TMP_DIR}" -maxdepth 1 -name "${ARCHIVE_PREFIX}*.tar.7z" | sort)

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "No archives matching '${ARCHIVE_PREFIX}*.tar.7z' found in ${TMP_DIR}"
        exit 1
    fi

    echo "Found ${#archives[@]} archive(s) to extract:"
    for archive in "${archives[@]}"; do
        echo "  ${archive}"
    done
    echo ""

    for archive in "${archives[@]}"; do
        base="$(basename "${archive}" .tar.7z)"
        dest="${TMP_DIR}/${base}"
        echo "Extracting: ${archive}"
        echo "       To:  ${dest}"
        mkdir -p "${dest}"
        7z x -so "${archive}" | tar xf - -C "${dest}"
        echo "Done: ${dest}"
        echo ""
    done
}

compress() {
    ARCHIVE_NAME="${ARCHIVE_PREFIX}_$(date +%Y%m%d_%H%M%S).tar.7z"
    OUTPUT="${TMP_DIR}/${ARCHIVE_NAME}"

    echo "Archiving: ${SCRIPT_DIR}"
    echo "Output:    ${OUTPUT}"
    echo ""

    tar cf - -C "${SCRIPT_DIR}" . \
        | 7z a -si -t7z -m0=lzma2 -mx=9 -mfb=273 -ms=on -md=128m "${OUTPUT}"

    SIZE=$(du -sh "${OUTPUT}" | cut -f1)
    echo ""
    echo "Done: ${OUTPUT} (${SIZE})"
}

if [[ "${1:-}" == "-d" ]]; then
    decompress
else
    compress
fi
