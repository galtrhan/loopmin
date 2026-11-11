package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Runs a command with ffmpeg-style semantics: no shell, arguments passed as a
// slice, stdout captured. stderr is only shown when the command fails.
run_cmd :: proc(command: []string) -> (stdout: []byte, ok: bool) {
	desc := os.Process_Desc {
		command = command,
	}
	state, out, err_out, err := os.process_exec(desc, context.allocator)
	if err != nil {
		fmt.eprintfln("loopmin: failed to run %s: %s", command[0], os.error_string(err))
		return nil, false
	}
	if !state.success || state.exit_code != 0 {
		message := strings.trim_space(string(err_out))
		if len(message) == 0 {
			message = fmt.aprintf("exit code %d", state.exit_code)
		}
		fmt.eprintfln("loopmin: %s failed: %s", command[0], message)
		return out, false
	}
	return out, true
}

probe_fps :: proc(input: string) -> (fps: f64, ok: bool) {
	out, ran := run_cmd(
		[]string {
			"ffprobe",
			"-v", "error",
			"-select_streams", "v:0",
			"-show_entries", "stream=avg_frame_rate",
			"-of", "default=nw=1:nk=1",
			input,
		},
	)
	if !ran {
		return 0, false
	}

	value := strings.trim_space(string(out))
	separator := strings.index_byte(value, '/')
	if separator < 0 {
		number, parsed := strconv.parse_f64(value)
		return number, parsed && number > 0
	}

	numerator, ok_numerator := strconv.parse_f64(value[:separator])
	denominator, ok_denominator := strconv.parse_f64(value[separator + 1:])
	if !ok_numerator || !ok_denominator || denominator == 0 {
		return 0, false
	}
	return numerator / denominator, true
}

// Decodes every frame to WxH grayscale in one ffmpeg pass. One frame per input
// frame, no duplication or dropping, so frame indices map to timestamps.
decode_gray :: proc(input: string, w, h: int) -> (frames: []u8, ok: bool) {
	filter := fmt.aprintf("scale=%d:%d:flags=area,format=gray", w, h)
	out, ran := run_cmd(
		[]string {
			"ffmpeg",
			"-v", "error",
			"-nostdin",
			"-i", input,
			"-vf", filter,
			"-fps_mode", "passthrough",
			"-f", "rawvideo",
			"-",
		},
	)
	if !ran {
		return nil, false
	}

	frame_bytes := w * h
	if len(out) < frame_bytes {
		fmt.eprintln("loopmin: ffmpeg produced no frames")
		return nil, false
	}
	usable := len(out) / frame_bytes * frame_bytes
	return out[:usable], true
}

// Grabs a single frame at a timestamp, downscaled to WxH grayscale.
grab_frame :: proc(input: string, at: f64, w, h: int) -> ([]u8, bool) {
	filter := fmt.aprintf("scale=%d:%d:flags=area,format=gray", w, h)
	out, ran := run_cmd(
		[]string {
			"ffmpeg",
			"-v", "error",
			"-nostdin",
			"-ss", fmt.aprintf("%.6f", at),
			"-i", input,
			"-vf", filter,
			"-frames:v", "1",
			"-f", "rawvideo",
			"-",
		},
	)
	if !ran || len(out) < w * h {
		return nil, false
	}
	return out[:w * h], true
}

export_clip :: proc(
	input, output: string,
	start, length: f64,
	frames: int,
	stream_copy, with_audio: bool,
	scale_width, scale_height: int,
) -> bool {
	command := make([dynamic]string, 0, 28)
	defer delete(command)

	append(&command, "ffmpeg", "-v", "error", "-nostdin", "-y")
	append(&command, "-ss", fmt.aprintf("%.6f", start))
	append(&command, "-i", input)

	if stream_copy {
		// Keyframe accurate only, but instant and lossless.
		append(&command, "-t", fmt.aprintf("%.6f", length))
		append(&command, "-c", "copy")
	} else {
		// Frame accurate: exactly `frames` frames starting at `start`.
		append(&command, "-frames:v", fmt.aprintf("%d", frames))
		if scale_width > 0 {
			filter: string
			if scale_height > 0 {
				filter = fmt.aprintf("scale=%d:%d", scale_width, scale_height)
			} else {
				// -2 keeps aspect and makes height even for yuv420p.
				filter = fmt.aprintf("scale=%d:-2", scale_width)
			}
			append(&command, "-vf", filter)
		}
		append(&command, "-c:v", "libx264", "-crf", "18", "-preset", "medium")
	}
	if !with_audio {
		append(&command, "-an")
	}
	append(&command, output)

	_, ran := run_cmd(command[:])
	return ran
}
