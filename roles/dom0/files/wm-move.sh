#!/bin/bash
# wm-move.sh
# Run in dom0. Moves/resizes the currently active window into one of the
# screen zones below, using wmctrl.
#
# Screen size is 5120x1440, but the usable area is 5112x1381 due to the
# Qubes toolbar and window frame decorations.
#
# Usage: wm-move.sh <l|r|c> [t|b]
#   l, r, c   horizontal position: left, right, center (required)
#   t, b      vertical position: top, bottom (optional)
#
# If the vertical position is omitted, the window spans the full usable
# height (top+bottom combined) at the chosen horizontal position.
#
# Command used: wmctrl -r :ACTIVE: -e 0,<X>,<Y>,<WIDTH>,<HEIGHT>

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <l|r|c> [t|b]
  l   left third
  c   center
  r   right third
  t   (optional) top half
  b   (optional) bottom half

Examples:
  $0 l      # left, full height
  $0 c t    # center, top
  $0 r b    # right, bottom
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 1
fi

HPOS="$1"
VPOS="${2:-}"

# Full usable height (usable screen height, minus toolbar/window frame)
HEIGHT_FULL=1381
HEIGHT_TOP=677
HEIGHT_BOTTOM=677

WIDTH_SIDE=1700
WIDTH_CENTER=1700

X_LEFT=0
X_CENTER=1706
X_RIGHT=3412

Y_TOP=0
Y_BOTTOM=735

case "$HPOS" in
    l) X=$X_LEFT;   WIDTH=$WIDTH_SIDE ;;
    c) X=$X_CENTER; WIDTH=$WIDTH_CENTER ;;
    r) X=$X_RIGHT;  WIDTH=$WIDTH_SIDE ;;
    *) usage; exit 1 ;;
esac

case "$VPOS" in
    t)  Y=$Y_TOP;    HEIGHT=$HEIGHT_TOP ;;
    b)  Y=$Y_BOTTOM; HEIGHT=$HEIGHT_BOTTOM ;;
    "") Y=$Y_TOP;    HEIGHT=$HEIGHT_FULL ;;
    *) usage; exit 1 ;;
esac

wmctrl -r :ACTIVE: -e 0,"$X","$Y","$WIDTH","$HEIGHT"
