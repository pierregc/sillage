#!/bin/bash
set -e
cd "$(dirname "$0")"
python3 tool.py render main photo webb ember v4
python3 tool.py render branch photo webb ember v4 y3 y3g06 y3k3 nodust nodust-y3 nodust-y3g06
for t in photo webb ember v4; do python3 tool.py same $t main branch; done
python3 tool.py measure main photo
python3 tool.py measure branch photo y3 y3g06 y3k3 nodust nodust-y3 nodust-y3g06
