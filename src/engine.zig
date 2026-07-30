const vk = @import("vulkan");
const sdl3 = @import("sdl3");
const std = @import("std");
const builtin = @import("builtin");

const FPS = 60;
const SCREEN_WIDTH = 640;
const SCREEN_HEIGHT = 480;
const SDL_FLAGS = sdl3.InitFlags{
    .video = true,
};

const Engine = @This();

allocator: std.mem.Allocator,
// vulkan objects
vkb: vk.BaseWrapper,
instance: vk.InstanceProxy,
gpu: vk.PhysicalDevice,
device: vk.DeviceProxy,
surface: vk.SurfaceKHR,
// sdl3 objects
window: sdl3.video.Window,

pub fn init(allocator: std.mem.Allocator) !Engine {
    try sdl3.init(SDL_FLAGS);

    var self: Engine = undefined;
    self.allocator = allocator;

    const libvulkanPath: [:0]const u8 = switch (builtin.os.tag) {
        .linux => "libvulkan.so.1",
        .macos => "libvulkan.1.dylib",
        .windows => "vulkan-1.dll",
        else => @panic("unsupported os"),
    };
    try sdl3.vulkan.loadLibrary(libvulkanPath);
    try self.initVulkan();

    const window_flags = sdl3.video.Window.Flags{
        .vulkan = true,
    };
    self.window = try .init("Hello Vulkan", SCREEN_WIDTH, SCREEN_HEIGHT, window_flags);

    var quit = false;
    while (!quit) {
        // Update logic.
        const surface = try self.window.getSurface();
        try surface.fillRect(null, surface.mapRgb(128, 30, 255));
        try self.window.updateSurface();

        // Event logic.
        while (sdl3.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                else => {},
            };
    }

    return self;
}

pub fn deinit(self: *Engine) void {
    self.window.deinit();

    self.instance.destroyInstance(null);
    // need to destroy wrappers as well to prevent mem leaks
    self.allocator.destroy(self.instance.wrapper);

    sdl3.vulkan.unloadLibrary();
    sdl3.quit(SDL_FLAGS);
    sdl3.shutdown();
}

const REQUIRED_LAYER_NAMES = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
fn initVulkan(self: *Engine) !void {
    const getInstanceProcAddr: vk.PfnGetInstanceProcAddr = @ptrCast(try sdl3.vulkan.getVkGetInstanceProcAddr());
    self.vkb = vk.BaseWrapper.load(getInstanceProcAddr);

    const extensions = try sdl3.vulkan.getInstanceExtensions();
    const instance = try self.vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "Example Vulkan App",
            .application_version = vk.makeApiVersion(1, 0, 0, 0).toU32(),
            .p_engine_name = "No Engine",
            .engine_version = vk.makeApiVersion(1, 0, 0, 0).toU32(),
            .api_version = vk.API_VERSION_1_3.toU32(),
        },
        .enabled_layer_count = REQUIRED_LAYER_NAMES.len,
        .pp_enabled_layer_names = @ptrCast(&REQUIRED_LAYER_NAMES),
        .enabled_extension_count = @intCast(extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
    }, null);

    const vki = try self.allocator.create(vk.InstanceWrapper);
    errdefer self.allocator.destroy(vki);
    vki.* = vk.InstanceWrapper.load(instance, getInstanceProcAddr);
    self.instance = vk.InstanceProxy.init(instance, vki);
    errdefer self.instance.destroyInstance(null);
}

fn initSwapchain() void {}
fn initCommands() void {}
fn initSyncStructures() void {}
