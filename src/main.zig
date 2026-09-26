const std = @import("std");
const sdl3 = @import("sdl3");
const vk = @import("vulkan");
const Camera = @import("Camera.zig");
const Instance = @import("vulkan/Instance.zig");
const Renderer = @import("vulkan/Renderer.zig");

const initial_width = 640;
const initial_height = 480;
const sdl_flags = sdl3.InitFlags{
    .video = true,
};

pub const tracy_impl = @import("tracy_impl");
pub const tracy = @import("tracy");

const Zone = tracy.Zone;

pub fn main(init: std.process.Init) !void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    tracy.frameMarkStart("main");
    tracy.appInfo("vulkan_obj_renderer");
    defer tracy.cleanExit(init.io);

    defer sdl3.shutdown();

    try sdl3.init(sdl_flags);
    defer sdl3.quit(sdl_flags);

    const window_flags = sdl3.video.Window.Flags{
        .vulkan = true,
        .resizable = true,
    };
    var window: sdl3.video.Window = try .init("Hello Vulkan", initial_width, initial_height, window_flags);
    defer window.deinit();

    const getInstanceProcAddr: vk.PfnGetInstanceProcAddr = @ptrCast(try sdl3.vulkan.getVkGetInstanceProcAddr());
    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    var instance: Instance = try .init(init.gpa, getInstanceProcAddr, sdl_exts);
    defer instance.deinit();

    const sdl_surface: sdl3.vulkan.Surface = try .init(window, @ptrFromInt(@intFromEnum(instance.proxy.handle)), null);
    var ctx: Renderer = try .init(&instance, @enumFromInt(@intFromPtr(sdl_surface.surface)), initial_width, initial_height, init.gpa);
    defer ctx.deinit();

    var cam: Camera = .init();

    var quit = false;
    var w: usize = initial_width;
    var h: usize = initial_height;
    var last_time: u64 = sdl3.timer.getNanosecondsSinceInit();
    while (!quit) {
        // Event logic.
        while (sdl3.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                .window_resized => |window_resized| {
                    w = @intCast(window_resized.width);
                    h = @intCast(window_resized.height);
                },
                .mouse_button_up => |mouse_button_up| if (mouse_button_up.button == .right)
                    try sdl3.mouse.setWindowRelativeMode(window, false),
                .mouse_button_down => |mouse_button_down| if (mouse_button_down.button == .right)
                    try sdl3.mouse.setWindowRelativeMode(window, true),
                .mouse_motion => |mouse_motion| cam.handleMouseMovement(sdl3.mouse.getWindowRelativeMode(window), mouse_motion.x_rel, mouse_motion.y_rel),
                .key_down => |key_down| if (key_down.key) |key| switch (key) {
                    .d => cam.input.x = 1,
                    .a => cam.input.x = -1,
                    .w => cam.input.y = 1,
                    .s => cam.input.y = -1,

                    else => {},
                },
                .key_up => |key_up| if (key_up.key) |key| switch (key) {
                    .d => cam.input.x = 0,
                    .a => cam.input.x = 0,
                    .w => cam.input.y = 0,
                    .s => cam.input.y = 0,

                    else => {},
                },
                else => {},
            };
        const current_time: u64 = sdl3.timer.getNanosecondsSinceInit();
        const dt: f32 = @floatCast(sdl3.timer.nanosecondsToSeconds(@floatFromInt(current_time - last_time)));
        last_time = current_time;
        cam.updateCamera(dt);
        cam.updateMatricies(w, h);

        if (w > 0 and h > 0) try ctx.render(w, h, cam.view, cam.proj);
    }
}
