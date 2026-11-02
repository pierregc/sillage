#!/bin/bash
# Runs one timed command for the tenfold study and writes a timestamped log.
#
#     run.sh <log> <command...>
#
# The command runs under `script` so its stdout is a terminal and line-buffered: piped, Swift's
# print is block-buffered and the timestamps would all land at the end. Each log line carries
# the seconds since just before launch.
set -uo pipefail
LOG="$1"
shift
gpu() {
    ioreg -r -d 1 -w 0 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | cut -d= -f2
}
others() {
    ps -Ao pid=,comm= | awk '$2 ~ /sillage-render$|\/Sillage$/ {print $1, $2}' | tr '\n' ';'
}
{
    echo "# $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# cmd: $*"
    echo "# before: gpu device utilization $(gpu) %, other sillage processes: [$(others)]"
} >"$LOG"
T0=$(python3 -c 'import time; print(time.time())')
script -q /dev/null /usr/bin/time -l "$@" </dev/null 2>&1 | T0=$T0 python3 -u -c '
import os, sys, time
t0 = float(os.environ["T0"])
for line in sys.stdin:
    line = line.replace("\r", "").replace("^D\b\b", "")
    print(f"{time.time() - t0:8.1f} {line}", end="")
' >>"$LOG"
echo "# after: $(date '+%Y-%m-%d %H:%M:%S'), gpu device utilization $(gpu) %, other sillage processes: [$(others)]" >>"$LOG"
