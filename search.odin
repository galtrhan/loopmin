package main

import "core:math"

// A frame reduced to a mean-centered, unit-length vector. The dot product of
// two descriptors is the normalized cross-correlation of the two frames.
Descriptor :: []f32

Scan_Params :: struct {
	fps:          f64,
	stride:       int,
	min_duration: f64,
	max_duration: f64, // 0 means "to the end of the video"
	threshold:    f32,
	min_motion:   f32,
	start_frame:  int,
	has_start:    bool,
}

Loop :: struct {
	start_frame: int,
	end_frame:   int,
	score:       f32,
}

// The coarse pass runs on small descriptors, where unrelated frames can still
// score high. Candidates are re-scored at a larger size before being accepted.
Verifier :: struct {
	input:      string,
	fps:        f64,
	stride:     int,
	width:      int,
	height:     int,
	threshold:  f32,
	checks:     int,
	max_checks: int,
	enabled:    bool,
}

MOTION_SAMPLES :: 48
DEFAULT_MIN_MOTION :: f32(0.00001)
DEFAULT_VERIFY_CHECKS :: 128

// Writes a mean-centered unit descriptor into `d`. `d` must be the same
// length as `pixels`. Callers keep descriptors in one contiguous slab so the
// O(n²) scan stays in cache.
fill_descriptor :: proc(pixels: []u8, d: Descriptor) {
	n := len(pixels)
	assert(len(d) == n)

	mean: f32
	for p in pixels {
		mean += f32(p)
	}
	mean /= f32(n)

	energy: f32
	#no_bounds_check {
		for i in 0 ..< n {
			value := f32(pixels[i]) - mean
			d[i] = value
			energy += value * value
		}
	}
	if energy > 1e-9 {
		inverse := 1.0 / math.sqrt(energy)
		#no_bounds_check {
			for i in 0 ..< n {
				d[i] *= inverse
			}
		}
	} else {
		// A flat frame has no structure to correlate. Make it a unit vector,
		// which is orthogonal to every mean-centered frame and identical to
		// every other flat frame.
		value := 1.0 / math.sqrt(f32(n))
		for i in 0 ..< n {
			d[i] = value
		}
	}
}

build_descriptor :: proc(pixels: []u8) -> Descriptor {
	d := make(Descriptor, len(pixels))
	fill_descriptor(pixels, d)
	return d
}

dot :: proc(a, b: Descriptor) -> f32 {
	score: f32
	#no_bounds_check {
		for i in 0 ..< len(a) {
			score += a[i] * b[i]
		}
	}
	return score
}

// Held frames score a perfect loop at any length. Require mean successive
// (1 - NCC) along the segment to clear min_motion; 0 disables the guard.
motion_ok :: proc(m: []Descriptor, first, last: int, min_motion: f32) -> bool {
	if min_motion <= 0 {
		return true
	}
	span := last - first
	if span <= 1 {
		return false
	}
	steps := MOTION_SAMPLES
	if span < steps {
		steps = span
	}
	need := min_motion * f32(steps)
	total: f32
	for s in 0 ..< steps {
		i := first + span*s/steps
		j := first + span*(s + 1)/steps
		total += 1 - dot(m[i], m[j])
		if total >= need {
			return true
		}
	}
	return false
}

// Walks gaps in increasing order, so the first gap that produces a usable pair
// is the shortest loop. A fixed start reduces this to a linear scan.
find_loop :: proc(m: []Descriptor, p: Scan_Params, verifier: ^Verifier) -> (Loop, bool) {
	n := len(m)
	if n < 2 {
		return {}, false
	}

	frames_per_second := p.fps / f64(p.stride)
	min_gap := int(math.ceil(p.min_duration * frames_per_second))
	if min_gap < 1 {
		min_gap = 1
	}
	max_gap := n - 1
	if p.max_duration > 0 {
		limit := int(math.floor(p.max_duration * frames_per_second))
		if limit < max_gap {
			max_gap = limit
		}
	}

	if p.has_start {
		first := p.start_frame
		if first < 0 || first >= n {
			return {}, false
		}
		for gap in min_gap ..= max_gap {
			last := first + gap
			if last >= n {
				break
			}
			score := dot(m[first], m[last])
			if score >= p.threshold &&
			   motion_ok(m, first, last, p.min_motion) &&
			   passes(verifier, first, last) {
				return Loop{first, last, score}, true
			}
		}
		return {}, false
	}

	// Prefer the top-scoring pair (one motion check). Only if that stretch is
	// frozen do we rescan for the best pair that clears the motion guard.
	for gap in min_gap ..= max_gap {
		best_first := -1
		best_score: f32 = -2
		for first in 0 ..< n - gap {
			score := dot(m[first], m[first + gap])
			if score > best_score {
				best_score = score
				best_first = first
			}
		}
		if best_first < 0 || best_score < p.threshold {
			continue
		}
		if motion_ok(m, best_first, best_first + gap, p.min_motion) {
			if passes(verifier, best_first, best_first + gap) {
				return Loop{best_first, best_first + gap, best_score}, true
			}
			continue
		}

		alt_first := -1
		alt_score: f32
		for first in 0 ..< n - gap {
			if first == best_first {
				continue
			}
			score := dot(m[first], m[first + gap])
			if score < p.threshold {
				continue
			}
			if alt_first >= 0 && score <= alt_score {
				continue
			}
			if !motion_ok(m, first, first + gap, p.min_motion) {
				continue
			}
			alt_score = score
			alt_first = first
		}
		if alt_first < 0 {
			continue
		}
		if passes(verifier, alt_first, alt_first + gap) {
			return Loop{alt_first, alt_first + gap, alt_score}, true
		}
	}

	return {}, false
}

// Re-score at verify size. Disabled verifier accepts. Spent check budget rejects.
passes :: proc(v: ^Verifier, first, last: int) -> bool {
	if v == nil || !v.enabled {
		return true
	}
	if v.checks >= v.max_checks {
		return false
	}
	v.checks += 1
	return verify_candidate(v, first, last)
}

verify_candidate :: proc(v: ^Verifier, first, last: int) -> bool {
	first_time := f64(first*v.stride) / v.fps
	last_time := f64(last*v.stride) / v.fps

	a, ok_a := grab_frame(v.input, first_time, v.width, v.height)
	b, ok_b := grab_frame(v.input, last_time, v.width, v.height)
	if !ok_a || !ok_b {
		// A decode hiccup should not silently reject an otherwise good loop.
		return true
	}
	return dot(build_descriptor(a), build_descriptor(b)) >= v.threshold
}
