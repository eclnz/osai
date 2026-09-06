package world

// Everything takes a seed. Same seed, identical level.
//
// Note that these are pure hash functions of (seed, coordinate), not a
// stateful RNG. That matters for chunked generation: a chunk must produce the
// same tiles no matter what order chunks are generated in, and a stateful
// stream would make the result depend on how the player wandered.

@(private)
splitmix64 :: proc(x: u64) -> u64 {
	z := x + 0x9e3779b97f4a7c15
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

hash2 :: proc(seed: u64, x, y: i32) -> u64 {
	h := seed
	h = splitmix64(h ~ u64(u32(x)) * 0x9e3779b97f4a7c15)
	h = splitmix64(h ~ u64(u32(y)) * 0xc2b2ae3d27d4eb4f)
	return h
}

// Uniform in [0, 1).
hash_unit :: proc(seed: u64, x, y: i32) -> f32 {
	return f32(hash2(seed, x, y) >> 40) / f32(1 << 24)
}

@(private)
smoothstep :: proc(t: f32) -> f32 {
	return t * t * (3 - 2 * t)
}

// Value noise: sample the hash on a lattice of `period` and interpolate.
// Cheap, good enough for terrain shape, and trivially seekable at any x.
value_noise_1d :: proc(seed: u64, x: f32, period: f32) -> f32 {
	p := x / period
	i := i32(p)
	if p < 0 && f32(i) != p {i -= 1}
	t := smoothstep(p - f32(i))
	a := hash_unit(seed, i, 0)
	b := hash_unit(seed, i + 1, 0)
	return a + (b - a) * t
}

value_noise_2d :: proc(seed: u64, x, y: f32, period: f32) -> f32 {
	px := x / period
	py := y / period
	ix := i32(px)
	iy := i32(py)
	if px < 0 && f32(ix) != px {ix -= 1}
	if py < 0 && f32(iy) != py {iy -= 1}
	tx := smoothstep(px - f32(ix))
	ty := smoothstep(py - f32(iy))

	a := hash_unit(seed, ix, iy)
	b := hash_unit(seed, ix + 1, iy)
	c := hash_unit(seed, ix, iy + 1)
	d := hash_unit(seed, ix + 1, iy + 1)

	top := a + (b - a) * tx
	bot := c + (d - c) * tx
	return top + (bot - top) * ty
}

// Sum of octaves. Each one is half the amplitude and half the wavelength of
// the last, which is what stops the result looking like a single sine wave.
fbm_1d :: proc(seed: u64, x: f32, period: f32, octaves: int) -> f32 {
	sum, amplitude, total: f32
	p := period
	amplitude = 1
	for i in 0 ..< octaves {
		sum += value_noise_1d(seed + u64(i) * 0x51ed270b, x, p) * amplitude
		total += amplitude
		amplitude *= 0.5
		p *= 0.5
	}
	return sum / total
}
