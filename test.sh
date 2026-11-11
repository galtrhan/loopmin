#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# A still image rotated a full turn every 4 seconds. Frame at 4s equals frame at
# 0s, so the only real loop in a 12 second clip is 4 seconds long.
ffmpeg -v error -y -f lavfi -i "color=c=0x101010:s=320x180:d=1" \
	-vf "drawbox=x=40:y=40:w=80:h=60:color=orange:t=fill,drawbox=x=200:y=100:w=60:h=40:color=cyan:t=fill" \
	-frames:v 1 still.png
ffmpeg -v error -y -loop 1 -i still.png \
	-vf "rotate=a=2*PI*t/4:fillcolor=0x101010,format=gray" \
	-t 12 -r 30 -c:v libx264 -pix_fmt yuv420p fixture.mp4

fail() { echo "FAIL: $*"; exit 1; }

# Fixed start at 0: the loop has to be exactly one rotation.
output=$("$here/loopmin" fixture.mp4 2 99 0 --no-export)
echo "$output"
grep -q "0.000s -> 4.000s" <<<"$output" || fail "expected a 4.000s loop from start 0"

# Free start: the shortest loop must land near one rotation.
output=$("$here/loopmin" fixture.mp4 2 95 --no-export)
echo "$output"
grep -Eq "\(3\.(8|9)[0-9]{2}s" <<<"$output" || fail "expected a loop just under 4s"

# Export has to produce exactly the reported frame count.
"$here/loopmin" fixture.mp4 2 99 0 -o loop.mp4 >/dev/null
frames=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=nw=1:nk=1 loop.mp4)
[ "$frames" = "120" ] || fail "expected 120 exported frames, got $frames"

# --scale sets the export width and keeps aspect.
"$here/loopmin" fixture.mp4 2 99 0 -o scaled.mp4 --scale 160 >/dev/null
width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 scaled.mp4)
height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 scaled.mp4)
[ "$width" = "160" ] || fail "expected scaled width 160, got $width"
[ "$height" = "90" ] || fail "expected scaled height 90, got $height"

# A static clip has nothing to loop back from once the motion guard is on.
ffmpeg -v error -y -f lavfi -i "color=c=red:s=160x90:r=25:d=5" -c:v libx264 -pix_fmt yuv420p static.mp4
if "$here/loopmin" static.mp4 2 95 --no-export >/dev/null 2>&1; then
	fail "static clip should not report a loop with default --min-motion"
fi

echo "ok"
