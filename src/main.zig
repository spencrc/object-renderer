const std = @import("std");
const sdl3 = @import("sdl3");
const vk = @import("vulkan");
const Instance = @import("engine/instance.zig");
const GraphicsContext = @import("engine/graphics_context.zig");
const Swapchain = @import("engine/swapchain.zig");

const FPS = 60;
const SCREEN_WIDTH = 640;
const SCREEN_HEIGHT = 480;
const SDL_FLAGS = sdl3.InitFlags{
    .video = true,
};

pub fn main(init: std.process.Init) !void {
    defer sdl3.shutdown();

    try sdl3.init(SDL_FLAGS);
    defer sdl3.quit(SDL_FLAGS);

    const window_flags = sdl3.video.Window.Flags{
        .vulkan = true,
    };
    var window: sdl3.video.Window = try .init("Hello Vulkan", SCREEN_WIDTH, SCREEN_HEIGHT, window_flags);
    defer window.deinit();

    const getInstanceProcAddr: vk.PfnGetInstanceProcAddr = @ptrCast(try sdl3.vulkan.getVkGetInstanceProcAddr());
    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    var instance: Instance = try .init(init.gpa, getInstanceProcAddr, sdl_exts);
    defer instance.deinit();

    const sdl_surface: sdl3.vulkan.Surface = try .init(window, @ptrFromInt(@intFromEnum(instance.proxy.handle)), null);
    var ctx: GraphicsContext = try .init(init.gpa, &instance, @enumFromInt(@intFromPtr(sdl_surface.surface)));
    defer ctx.deinit();

    var swapchain: Swapchain = try .init(&ctx, SCREEN_WIDTH, SCREEN_HEIGHT, init.gpa);
    defer swapchain.deinit();

    var quit = false;
    while (!quit) {
        // Event logic.
        while (sdl3.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                else => {},
            };
    }
}
