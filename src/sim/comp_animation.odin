package sim

// The animation vocabulary: what an animation is, and the table of them.
//
// Split from the system that drives it (sys_animation.odin) so that every
// component group in this package follows the same rule - data here, behaviour
// in a sys_ file. Animation was the one exception, and the exception is what
// made `Presentation` - which holds a `Sparse_Set(Animation_State)` - depend on
// a file full of procedures that take a `^State`.

Animation_Id :: enum u8 {
	Idle,
	Run,
	Jump,
	Fall,
	Hurt,
	Death,
}

// Ordered widest-first, and `frame` is a u8 rather than an int.
//
// No animation has more than a handful of frames - the longest in the table
// below is five - so the frame index never needed eight bytes, and an int
// there forced the whole struct to eight-byte alignment. Laid out this way it
// is 12 bytes instead of 24, which halves the array `animation_system` streams
// once per entity per frame.
Animation_State :: struct {
	elapsed:          f32,
	// A command outranks derivation while it is unexpired. See
	// sys_animation.odin for how a command is resolved against derivation.
	command_expiry:   f32,
	current:          Animation_Id,
	commanded:        Animation_Id,
	frame:            u8,
	command_priority: u8,
}
#assert(size_of(Animation_State) == 12)

Animation_Definition :: struct {
	frames:     int,
	frame_time: f32,
	loops:      bool,
}

// Indexed by type ID, one entry per type. Not saved - see entity_definitions.
@(rodata)
animation_definitions := [Animation_Id]Animation_Definition {
	.Idle  = {frames = 4, frame_time = 0.20, loops = true},
	.Run   = {frames = 6, frame_time = 0.08, loops = true},
	.Jump  = {frames = 2, frame_time = 0.12, loops = false},
	.Fall  = {frames = 2, frame_time = 0.12, loops = false},
	.Hurt  = {frames = 2, frame_time = 0.10, loops = false},
	.Death = {frames = 5, frame_time = 0.12, loops = false},
}
