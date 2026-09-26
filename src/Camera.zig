const Camera = @This();

const std = @import("std");
const vec3 = @import("math.zig").Vec3;
const mat4 = @import("math.zig").Mat4;

const starting_position: vec3 = vec3{ .x = 0.0, .y = -1.0, .z = 0.0 };
const far = 10;

position: vec3 = starting_position,
yaw: f32,
pitch: f32,
input: vec3 = vec3.zero(),
target: vec3 = vec3.zero(),
proj: mat4 = mat4.persp(75.0, 1, 0.1, far),
view: mat4 = mat4.lookat(starting_position, vec3.zero(), vec3.up()),

pub fn init() Camera {
    const forward = vec3{ .x = 0, .y = 1, .z = 0 };
    return .{
        .yaw = std.math.atan2(forward.y, forward.x),
        .pitch = std.math.asin(forward.z),
    };
}

const speed = 7;
pub fn updateCamera(self: *Camera, dt: f32) void {
    const multiplier = speed * dt;

    const ch = @cos(self.yaw);
    const sh = @sin(self.yaw);
    const cp = @cos(self.pitch);
    const sp = @sin(self.pitch);
    //code following this line was adapted from here: https://github.com/nadako/hello-sokol-odin/blob/master/main.odin
    const forward = vec3{ .x = cp * ch, .y = cp * sh, .z = sp };
    const right = vec3.norm(vec3.cross(forward, vec3.up()));

    const move_dir = vec3.add(vec3.mul(forward, self.input.y), vec3.mul(right, self.input.x));
    const motion = vec3.mul(vec3.norm(move_dir), multiplier);

    self.position.x += motion.x;
    self.position.y += motion.y;
    self.position.z += motion.z;

    self.target = vec3.add(self.position, forward);
}

pub fn updateMatricies(self: *Camera, width: usize, height: usize) void {
    const f_width: f32 = @floatFromInt(width);
    const f_height: f32 = @floatFromInt(height);
    self.view = mat4.lookat(self.position, self.target, vec3.up());
    self.proj = mat4.persp(75.0, f_width / f_height, 0.1, far);
}

const sens = 0.004;
pub fn handleMouseMovement(self: *Camera, is_mouse_locked: bool, dx: f32, dy: f32) void {
    if (!is_mouse_locked)
        return;

    self.yaw -= dx * sens;
    self.pitch -= dy * sens;
    //wrap yap to be in interval [0, 360]
    self.yaw = @mod(self.yaw, 2 * std.math.pi);
    //clamp pitch to be in interval (-90, 90)
    const max_pitch = std.math.pi / 2.0 - 0.01;
    self.pitch = @max(-max_pitch, @min(max_pitch, self.pitch));
}
