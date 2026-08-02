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
debug_messenger: if (builtin.mode == .Debug) vk.DebugUtilsMessengerEXT else void,
surface: vk.SurfaceKHR,
gpu: vk.PhysicalDevice,
device: vk.DeviceProxy,
// sdl3 objects
window: sdl3.video.Window,

pub fn init(allocator: std.mem.Allocator) !Engine {
    try sdl3.init(SDL_FLAGS);

    var self: Engine = undefined;
    self.allocator = allocator;

    const window_flags = sdl3.video.Window.Flags{
        .vulkan = true,
    };
    self.window = try .init("Hello Vulkan", SCREEN_WIDTH, SCREEN_HEIGHT, window_flags);

    try self.initVulkan();

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

    return self;
}

pub fn deinit(self: *Engine) void {
    if (builtin.mode == .Debug) {
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    }
    self.instance.destroySurfaceKHR(self.surface, null);
    self.instance.destroyInstance(null);
    // need to destroy wrappers as well to prevent mem leaks
    self.allocator.destroy(self.instance.wrapper);

    self.window.deinit();
    sdl3.quit(SDL_FLAGS);
    sdl3.shutdown();
}

fn initVulkan(self: *Engine) !void {
    const getInstanceProcAddr: vk.PfnGetInstanceProcAddr = @ptrCast(try sdl3.vulkan.getVkGetInstanceProcAddr());
    self.vkb = vk.BaseWrapper.load(getInstanceProcAddr);

    const required_layers = comptime getRequiredLayers();

    var instances_exts: std.ArrayList([*:0]const u8) = .empty;
    defer instances_exts.deinit(self.allocator);
    try instances_exts.appendSlice(self.allocator, comptime getInstanceExtensions());
    try instances_exts.appendSlice(self.allocator, try sdl3.vulkan.getInstanceExtensions());

    const instance = try self.vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "Example Vulkan App",
            .application_version = vk.makeApiVersion(1, 0, 0, 0).toU32(),
            .p_engine_name = "No Engine",
            .engine_version = vk.makeApiVersion(1, 0, 0, 0).toU32(),
            .api_version = vk.API_VERSION_1_3.toU32(),
        },
        .enabled_layer_count = @intCast(required_layers.len),
        .pp_enabled_layer_names = required_layers.ptr,
        .enabled_extension_count = @intCast(instances_exts.items.len),
        .pp_enabled_extension_names = instances_exts.items.ptr,
    }, null);

    const vki = try self.allocator.create(vk.InstanceWrapper);
    errdefer self.allocator.destroy(vki);
    vki.* = vk.InstanceWrapper.load(instance, getInstanceProcAddr);
    self.instance = vk.InstanceProxy.init(instance, vki);
    errdefer self.instance.destroyInstance(null);

    // if (builtin.mode == .Debug) {
    //     self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
    //         .message_severity = .{
    //             .warning_bit_ext = true,
    //             .error_bit_ext = true,
    //         },
    //         .message_type = .{
    //             .general_bit_ext = true,
    //             .validation_bit_ext = true,
    //             .performance_bit_ext = true,
    //         },
    //         .pfn_user_callback = null,
    //         .p_user_data = null,
    //     }, null);
    // }

    const sdl_surface: sdl3.vulkan.Surface = try .init(self.window, @ptrFromInt(@intFromEnum(self.instance.handle)), null);
    self.surface = @enumFromInt(@intFromPtr(sdl_surface.surface));
    errdefer self.instance.destroySurfaceKHR(self.surface, null);
}

fn getRequiredLayers() []const [*:0]const u8 {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => &[_][*:0]const u8{"VK_LAYER_KHRONOS_validation"},
        else => &[_][*:0]const u8{},
    };
}

fn getInstanceExtensions() []const [*:0]const u8 {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => &[_][*:0]const u8{vk.extensions.ext_debug_utils.name},
        else => &[_][*:0]const u8{},
    };
}

fn initSwapchain() void {}
fn initCommands() void {}
fn initSyncStructures() void {}
