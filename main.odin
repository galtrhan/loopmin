package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

USAGE :: `loopmin - find the shortest seamlessly loopable segment in a video

usage:
  loopmin <input> <min-duration> <similarity> [start] [options]

arguments:
  input          video file, anything ffmpeg can decode
  min-duration   minimum loop length in seconds
  similarity     minimum first/last frame similarity, 0..100
  start          optional fixed start time in seconds; when omitted the
                 whole clip is searched for the shortest loop

options:
  -o, --output <path>    output file (default: <input>-loop.mp4)
      --max-duration <s> longest loop to consider (default: end of video)
      --size <WxH>       descriptor size (default 32x18)
      --stride <n>       analyze every nth frame (default 1)
      --min-motion <f>   minimum mean frame-to-frame change inside the loop
                         (1 - NCC); 0 disables (default 0.00001)
      --verify <WxH>     re-score the winning pair at this size; "off" skips
                         (default 128x72)
      --scale <W|WxH>    scale the exported file; width alone keeps aspect
      --no-export        report only, write no file
      --copy             stream copy instead of re-encoding (keyframe accurate)
      --with-audio       keep audio (dropped by default)
  -h, --help
`

Options :: struct {
	input:        string,
	min_duration: f64,
	similarity:   f64,
	start:        f64,
	has_start:    bool,
	max_duration: f64,
	width:        int,
	height:       int,
	stride:       int,
	min_motion:   f32,
	verify:       bool,
	verify_width: int,
	verify_height: int,
	scale_width:  int,
	scale_height: int,
	output:       string,
	export:       bool,
	copy:         bool,
	with_audio:   bool,
}

main :: proc() {
	opts, ok := parse_args(os.args)
	if !ok {
		fmt.eprintln(USAGE)
		os.exit(2)
	}

	fps, ok_fps := probe_fps(opts.input)
	if !ok_fps {
		fmt.eprintfln("loopmin: could not read the frame rate of %s", opts.input)
		os.exit(1)
	}

	fmt.eprintfln("loopmin: decoding %dx%d frames at %.3f fps", opts.width, opts.height, fps)
	raw, ok_decode := decode_gray(opts.input, opts.width, opts.height)
	if !ok_decode {
		os.exit(1)
	}

	frame_bytes := opts.width * opts.height
	decoded := len(raw) / frame_bytes
	n := decoded / opts.stride
	if n < 2 {
		fmt.eprintln("loopmin: need at least two frames")
		os.exit(1)
	}
	fmt.eprintfln(
		"loopmin: %d frames, %.3fs of video, analyzing %d of them",
		decoded,
		f64(decoded)/fps,
		n,
	)

	// One slab of descriptors keeps the pairwise scan sequential in memory.
	dim := frame_bytes
	slab := make([]f32, n * dim)
	m := make([]Descriptor, n)
	for i in 0 ..< n {
		source := i * opts.stride
		m[i] = slab[i * dim:(i + 1) * dim]
		fill_descriptor(raw[source * frame_bytes:(source + 1) * frame_bytes], m[i])
	}

	params := Scan_Params {
		fps          = fps,
		stride       = opts.stride,
		min_duration = opts.min_duration,
		max_duration = opts.max_duration,
		threshold    = f32(opts.similarity / 100),
		min_motion   = opts.min_motion,
		has_start    = opts.has_start,
	}
	if opts.has_start {
		params.start_frame = round_int(opts.start * fps / f64(opts.stride))
	}

	verifier := Verifier {
		input      = opts.input,
		fps        = fps,
		stride     = opts.stride,
		width      = opts.verify_width,
		height     = opts.verify_height,
		threshold  = params.threshold,
		max_checks = DEFAULT_VERIFY_CHECKS,
		enabled    = opts.verify,
	}

	started := time.now()
	loop, found := find_loop(m, params, &verifier)
	elapsed := time.duration_seconds(time.since(started))

	if !found {
		fmt.printfln(
			"no loop: no frame pair clears %.1f%% similarity with at least %.3fs between them",
			opts.similarity,
			opts.min_duration,
		)
		fmt.printfln("searched %d frames in %.2fs", n, elapsed)
		os.exit(1)
	}

	start_s := f64(loop.start_frame*opts.stride) / fps
	end_s := f64(loop.end_frame*opts.stride) / fps
	length := end_s - start_s
	frames := (loop.end_frame - loop.start_frame) * opts.stride

	fmt.printfln(
		"loop %.3fs -> %.3fs  (%.3fs, %d frames, similarity %.2f%%)",
		start_s,
		end_s,
		length,
		frames,
		f64(loop.score)*100,
	)
	fmt.printfln("searched %d frames in %.2fs", n, elapsed)

	if !opts.export {
		return
	}

	out := opts.output
	if out == "" {
		out = default_output(opts.input)
	}
	if !export_clip(
		opts.input,
		out,
		start_s,
		length,
		frames,
		opts.copy,
		opts.with_audio,
		opts.scale_width,
		opts.scale_height,
	) {
		os.exit(1)
	}
	fmt.printfln("wrote %s", out)
}

parse_args :: proc(argv: []string) -> (opts: Options, ok: bool) {
	opts.width = 32
	opts.height = 18
	opts.stride = 1
	opts.min_motion = DEFAULT_MIN_MOTION
	opts.verify = true
	opts.verify_width = 128
	opts.verify_height = 72
	opts.export = true

	positional := make([dynamic]string, 0, 4)
	defer delete(positional)

	for i := 1; i < len(argv); i += 1 {
		arg := argv[i]
		if len(arg) == 0 || arg[0] != '-' {
			append(&positional, arg)
			continue
		}

		switch arg {
		case "-h", "--help":
			fmt.println(USAGE)
			os.exit(0)
		case "--no-export":
			opts.export = false
		case "--copy":
			opts.copy = true
		case "--with-audio":
			opts.with_audio = true
		case "-o", "--output":
			value, got := next_value(argv, &i)
			if !got {
				return {}, false
			}
			opts.output = value
		case "--max-duration":
			value, got := next_value(argv, &i)
			if !got {
				return {}, false
			}
			number, parsed := strconv.parse_f64(value)
			if !parsed {
				return {}, false
			}
			opts.max_duration = number
		case "--size":
			value, got := next_value(argv, &i)
			if !got {
				return {}, false
			}
			w, h, sized := parse_size(value)
			if !sized {
				return {}, false
			}
			opts.width = w
			opts.height = h
		case "--stride":
			value, got := next_value(argv, &i)
			if !got {
				return {}, false
			}
			number, parsed := strconv.parse_int(value)
			if !parsed {
				return {}, false
			}
			opts.stride = number
		case "--verify":
			value, got := next_value(argv, &i)
			if !got {
				return {}, false
			}
			if value == "off" {
				opts.verify = false
			} else {
				w, h, sized := parse_size(value)
				if !sized {
					return {}, false
				}
				opts.verify_width = w
				opts.verify_height = h
			}
		case "--min-motion":
			value, got := next_value(argv, &i)
			if !got {
				return {}, false
			}
			number, parsed := strconv.parse_f64(value)
			if !parsed {
				return {}, false
			}
			opts.min_motion = f32(number)
		case "--scale":
			value, got := next_value(argv, &i)
			if !got {
				return {}, false
			}
			w, h, scaled := parse_scale(value)
			if !scaled {
				return {}, false
			}
			opts.scale_width = w
			opts.scale_height = h
		case:
			fmt.eprintfln("loopmin: unknown option %s", arg)
			return {}, false
		}
	}

	if len(positional) < 3 || len(positional) > 4 {
		return {}, false
	}

	opts.input = positional[0]

	min_duration, parsed_duration := strconv.parse_f64(positional[1])
	if !parsed_duration {
		fmt.eprintfln("loopmin: bad min-duration %s", positional[1])
		return {}, false
	}
	opts.min_duration = min_duration

	similarity, parsed_similarity := strconv.parse_f64(positional[2])
	if !parsed_similarity {
		fmt.eprintfln("loopmin: bad similarity %s", positional[2])
		return {}, false
	}
	opts.similarity = similarity

	if len(positional) == 4 {
		start, parsed_start := strconv.parse_f64(positional[3])
		if !parsed_start {
			fmt.eprintfln("loopmin: bad start %s", positional[3])
			return {}, false
		}
		opts.start = start
		opts.has_start = true
	}

	if opts.min_duration <= 0 || opts.similarity <= 0 || opts.similarity > 100 {
		fmt.eprintln("loopmin: min-duration must be > 0 and similarity in (0, 100]")
		return {}, false
	}
	if opts.stride < 1 || opts.min_motion < 0 || opts.min_motion > 1 {
		fmt.eprintln("loopmin: stride must be >= 1 and min-motion in [0, 1]")
		return {}, false
	}
	if opts.copy && opts.scale_width > 0 {
		fmt.eprintln("loopmin: --scale needs re-encoding; drop --copy")
		return {}, false
	}

	return opts, true
}

next_value :: proc(argv: []string, i: ^int) -> (string, bool) {
	i^ += 1
	if i^ >= len(argv) {
		return "", false
	}
	return argv[i^], true
}

parse_size :: proc(s: string) -> (w, h: int, ok: bool) {
	separator := strings.index_byte(s, 'x')
	if separator < 0 {
		return 0, 0, false
	}
	width, ok_width := strconv.parse_int(s[:separator])
	height, ok_height := strconv.parse_int(s[separator + 1:])
	if !ok_width || !ok_height || width < 2 || height < 2 {
		return 0, 0, false
	}
	return width, height, true
}

// Width alone keeps aspect (height 0). WxH sets both.
parse_scale :: proc(s: string) -> (w, h: int, ok: bool) {
	if strings.index_byte(s, 'x') >= 0 {
		return parse_size(s)
	}
	width, parsed := strconv.parse_int(s)
	if !parsed || width < 2 {
		return 0, 0, false
	}
	return width, 0, true
}

default_output :: proc(input: string) -> string {
	stem := input
	dot := strings.last_index_byte(input, '.')
	slash := strings.last_index_byte(input, '/')
	if dot > slash {
		stem = input[:dot]
	}
	return fmt.aprintf("%s-loop.mp4", stem)
}

round_int :: proc(x: f64) -> int {
	return int(math.round(x))
}
