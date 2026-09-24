#!/bin/bash
# Unattended JDownloader 2 install from the bootstrap JDownloader.jar.
# Usage: install-jdownloader2.sh <install dir> <timeout per pass, seconds>
#
# The launcher needs more than one headless run:
#   pass 1: only self-updates JDownloader.jar, then exits (no Core.jar yet)
#   pass 2: installs Core.jar and the libraries, logs "Launchstate: LAUNCHING_JD",
#           then starts JDownloader, which never exits on its own
# so each pass is stopped with SIGTERM (JDownloader shuts down cleanly) as soon as
# that hand-over is logged. Never replace JDownloader.jar afterwards: the updated
# launcher must match Core.jar, the bootstrap one crashes the GUI at startup.
set -u

install_dir=$1
pass_timeout=$2
max_passes=3

cd "$install_dir" || exit 1

for ((pass = 1; pass <= max_passes; pass++)); do
    [ -f Core.jar ] && exit 0

    log=$(mktemp)
    java -Djava.awt.headless=true -jar JDownloader.jar -norestart >"$log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + pass_timeout))

    while kill -0 "$pid" 2>/dev/null; do
        if grep -q "Launchstate: LAUNCHING_JD" "$log"; then
            kill "$pid"
            break
        fi
        if ((SECONDS >= deadline)); then
            echo "pass $pass: no hand-over after ${pass_timeout}s, stopping" >&2
            kill "$pid"
            break
        fi
        sleep 1
    done
    wait "$pid"
    rm -f "$log"
done

if [ ! -f Core.jar ]; then
    echo "Core.jar still missing after $max_passes passes" >&2
    exit 1
fi
