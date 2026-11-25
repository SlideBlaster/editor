#!/bin/bash
# Checks of the editor in a headless Chrome of its own, against `sb serve`.
#
#   hosts/web/test/browser/run.sh arrange          select, align, turn, flip, order, copy on slide pictures
#   hosts/web/test/browser/run.sh lines            bent and right-angled lines, labels, points
#   hosts/web/test/browser/run.sh figures          TikZ figures drawn by the core: how many, and how their text fits
#   hosts/web/test/browser/run.sh figures edit     ... then drag, retype, recolour, delete (inline and file figures)
#   hosts/web/test/browser/run.sh figures build    ... then add a node, join, resize, re-route, move two together
#
# Each run works on a copy of its deck in a temporary folder and prints what the
# source says after every step; screenshots land beside that copy. Needs the web
# host built (npm run build in hosts/web), `sb` built, node and google-chrome.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
check=${1:?which check: arrange, lines or figures}
steps=${2:-}
sb=$(cd "$root" && PATH=$HOME/.ghcup/bin:$PATH cabal list-bin exe:sb --project-file=cabal.project.native | tail -1)
work=$(mktemp -d)
cp -r "$here/decks/$check/." "$work/"
"$sb" serve "$work" --port 0 --web "$root/hosts/web" > "$work/serve.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
for _ in $(seq 1 80); do grep -q SB_READY "$work/serve.log" && break; sleep 0.25; done
port=$(grep -o "port=[0-9]*" "$work/serve.log" | head -1 | cut -d= -f2)
if [ -n "$steps" ]; then export SB_STEPS="$here/$check-$steps.mjs"; fi
node "$here/$check.mjs" "http://127.0.0.1:$port/" "$work"
echo "deck and screenshots: $work"
