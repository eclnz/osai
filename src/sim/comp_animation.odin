package sim

// Animation vocabulary and its definition table. The system that drives it is
// in sys_animation.odin.

Animation_Id :: enum u8 {
	Idle,
	Run,
	Jump,
	Fall,
	Hurt,
	Death,
}

// Ordered widest-first, and `frame` is a u8: no animation has more than a
// handful of frames, and an `int` there forced the struct to eight-byte
// alignment and 24 bytes. The assert is what holds the layout.
Animation_State :: struct {
	elapsed:          f32,
	// Positive means a command is live and outranks derivation.
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

// Indexed by type ID. Not saved - see entity_definitions.
@(rodata)
animation_definitions := [Animation_Id]Animation_Definition {
	.Idle  = {frames = 4, frame_time = 0.20, loops = true},
	.Run   = {frames = 6, frame_time = 0.08, loops = true},
	.Jump  = {frames = 2, frame_time = 0.12, loops = false},
	.Fall  = {frames = 2, frame_time = 0.12, loops = false},
	.Hurt  = {frames = 2, frame_time = 0.10, loops = false},
	.Death = {frames = 5, frame_time = 0.12, loops = false},
}
