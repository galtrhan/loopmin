# loopmin

Finds the shortest segment of a video that can loop without a visible seam, and cuts it.

You give it a minimum loop length and a similarity threshold. It returns the shortest
segment whose last frame looks like its first frame, so playback can jump back to the
start without a pop.

```
$ loopmin clip.mp4 2 95
loopmin: decoding 32x18 frames at 30.000 fps
loopmin: 360 frames, 12.000s of video, analyzing 360 of them
loop 7.100s -> 11.067s  (3.967s, 119 frames, similarity 100.00%)
searched 360 frames in 0.34s
wrote clip-loop.mp4
```

## How it works

1. `ffmpeg` decodes every frame once to a 32x18 grayscale raw stream.
2. Each frame becomes a mean-centered, unit-length vector. The dot product of two
   vectors is the normalized cross-correlation of the frames, from -1 to 1.
3. Gaps are scanned in increasing order, starting at the minimum length. The first gap
   that has a pair above the threshold wins, so the result is the shortest loop, not
   the best one.
4. That pair is re-scored at 128x72. Coarse descriptors cannot tell a 3 degree
   rotation from no rotation, and this check catches that.
5. `ffmpeg` cuts the segment. Frame count, not timestamp, so the cut is exact.

With a fixed start time, step 3 is a linear scan forward from that frame.

The scan is O(n²) in frames and O(n) in memory. A 10 minute clip at 30 fps is about
41 MB of descriptors and takes roughly a minute when nothing matches. Use `--stride`
to trade precision for speed on long videos.

## Build

Needs Odin and ffmpeg on `PATH`.

```
make
```

or

```
odin build . -out:loopmin -o:speed
```

## Usage

```
loopmin <input> <min-duration> <similarity> [start] [options]
```

| argument | meaning |
| --- | --- |
| `input` | any video ffmpeg can decode |
| `min-duration` | minimum loop length in seconds |
| `similarity` | minimum first/last frame similarity, 0 to 100 |
| `start` | optional fixed start in seconds; omit to search the whole clip |

| option | default | meaning |
| --- | --- | --- |
| `-o, --output` | `<input>-loop.mp4` | output file |
| `--max-duration` | whole video | longest loop to consider |
| `--size` | `32x18` | descriptor size for the scan |
| `--stride` | `1` | analyze every nth frame |
| `--min-motion` | `0.5` | reject segments that never leave their first frame; `0` disables |
| `--verify` | `128x72` | re-score size; `off` skips the check |
| `--no-export` | | report only |
| `--copy` | | stream copy instead of re-encoding |
| `--with-audio` | | keep audio |

Examples:

```
# shortest loop of at least 3 seconds anywhere in the clip
loopmin drone.mp4 3 95

# loop must start at 12.5s
loopmin drone.mp4 2 98 12.5

# find the loop but do not write a file
loopmin drone.mp4 2 95 --no-export

# long video, check every third frame
loopmin talk.mp4 5 90 --stride 3
```

## What it does not do

Similarity is global normalized cross-correlation, so a large static background
dominates the score. A small moving object can jump while the number stays high. If
that matters, raise `--verify` to something like `320x180` and lower the threshold
until the seams look right.

`--min-motion` exists because a held camera "loops" instantly and uselessly. It
samples the segment and requires at least one frame to fall below the given
similarity to the start frame. Turn it off for loops with very little motion.

Audio is dropped by default. A loop usually cuts mid-word or mid-beat, and silence
is less wrong than a stutter.

`--copy` avoids re-encoding but snaps to the previous keyframe, so the exported
length can differ from the reported one. The default re-encodes with libx264 CRF 18
for a frame-exact cut.

Variable frame rate videos use the average frame rate, so timestamps can drift
slightly on those.

## Why ffmpeg

Odin has no video decoder in its standard library, and linking libav* would triple
the code for no gain here. The interesting part is the search, and ffmpeg already
does decode and encode well. The program shells out with an argument slice, no shell
involved, so filenames with spaces are fine.

## License

MIT. Redistributing it, modified or not, means keeping the copyright notice and
the permission notice in the source. See `LICENSE`.

