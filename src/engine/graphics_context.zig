const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("sdl3");

const QueueFamilyIndices = struct {
    graphics_family_index: u32,
    present_family_index: u32,
};

const DeviceCandidate = struct {
    pdevice: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueFamilyIndices,
};

const Engine = @This();

allocator: std.mem.Allocator,
// vulkan objects
vkb: vk.BaseWrapper,
instance: vk.InstanceProxy,
debug_messenger: if (builtin.mode == .Debug) vk.DebugUtilsMessengerEXT else void,
surface: vk.SurfaceKHR,

pdevice: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,

graphics_family_index: u32,
present_family_index: u32,

device: vk.DeviceProxy,

pub fn deinit(self: *Engine) void {
    self.device.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    if (builtin.mode == .Debug) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);
    // need to destroy wrappers as well to prevent mem leaks
    self.allocator.destroy(self.device.wrapper);
    self.allocator.destroy(self.instance.wrapper);
}

pub fn init(
    allocator: std.mem.Allocator,
    getInstanceProcAddr: vk.PfnGetInstanceProcAddr,
    backend_extensions: []const [*:0]const u8,
    window: sdl3.video.Window,
) !Engine {
    var self: Engine = undefined;
    self.allocator = allocator;
    self.vkb = vk.BaseWrapper.load(getInstanceProcAddr);

    if (try checkLayerSupport(&self.vkb, self.allocator) == false) return error.MissingLayer;
    const required_layers = comptime getRequiredLayers();

    var instances_exts: std.ArrayList([*:0]const u8) = .empty;
    defer instances_exts.deinit(self.allocator);
    try instances_exts.appendSlice(self.allocator, comptime getInstanceExtensions());
    try instances_exts.appendSlice(self.allocator, backend_extensions);

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

    if (builtin.mode == .Debug) {
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
            .message_severity = .{
                .warning_bit_ext = true,
                .error_bit_ext = true,
            },
            .message_type = .{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
            },
            .pfn_user_callback = &debugUtilsMessengerCallback,
            .p_user_data = null,
        }, null);
    }

    const sdl_surface: sdl3.vulkan.Surface = try .init(window, @ptrFromInt(@intFromEnum(self.instance.handle)), null);
    self.surface = @enumFromInt(@intFromPtr(sdl_surface.surface));
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    const candidate = try pickCandidateDevice(self.instance, self.surface, self.allocator);
    self.pdevice = candidate.pdevice;
    self.props = candidate.props;
    self.graphics_family_index = candidate.queues.graphics_family_index;
    self.present_family_index = candidate.queues.present_family_index;

    const priority = [_]f32{1};
    const required_device_extensions = comptime getRequiredDeviceExtensions();
    const device = try self.instance.createDevice(self.pdevice, &.{
        .queue_create_info_count = if (candidate.queues.graphics_family_index == candidate.queues.present_family_index) 1 else 2,
        .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = candidate.queues.graphics_family_index,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .queue_family_index = candidate.queues.present_family_index,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        },
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = required_device_extensions.ptr,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
    }, null);

    const vkd = try self.allocator.create(vk.DeviceWrapper);
    errdefer self.allocator.destroy(vkd);
    vkd.* = vk.DeviceWrapper.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    self.device = vk.DeviceProxy.init(device, vkd);
    errdefer self.device.destroyDevice(null);

    return self;
}

fn checkLayerSupport(vkb: *const vk.BaseWrapper, allocator: std.mem.Allocator) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(available_layers);

    const required_layers = comptime getRequiredLayers();

    for (required_layers) |required_layer| {
        for (available_layers) |layer| {
            if (std.mem.eql(u8, std.mem.span(required_layer), std.mem.sliceTo(&layer.layer_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

const EMPTY_NAMES = [_][*:0]const u8{};
const DEBUG_REQUIRED_LAYERS = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"}; // will be DCE'd if not in Debug or ReleaseSafe
fn getRequiredLayers() []const [*:0]const u8 {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => &DEBUG_REQUIRED_LAYERS,
        else => &EMPTY_NAMES,
    };
}

const DEBUG_INSTANCE_EXTS = [_][*:0]const u8{vk.extensions.ext_debug_utils.name}; // will be DCE'd if not in Debug or ReleaseSafe
fn getInstanceExtensions() []const [*:0]const u8 {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => &DEBUG_INSTANCE_EXTS,
        else => &EMPTY_NAMES,
    };
}

fn debugUtilsMessengerCallback(severity: vk.DebugUtilsMessageSeverityFlagsEXT, msg_type: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(.c) vk.Bool32 {
    const severity_str = if (severity.verbose_bit_ext) "verbose" else if (severity.info_bit_ext) "info" else if (severity.warning_bit_ext) "warning" else if (severity.error_bit_ext) "error" else "unknown";

    const type_str = if (msg_type.general_bit_ext) "general" else if (msg_type.validation_bit_ext) "validation" else if (msg_type.performance_bit_ext) "performance" else if (msg_type.device_address_binding_bit_ext) "device addr" else "unknown";

    const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.p_message else "NO MESSAGE!";
    std.debug.print("[{s}][{s}]. Message:\n  {s}\n", .{ severity_str, type_str, message });

    return .false;
}

fn pickCandidateDevice(
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !DeviceCandidate {
    const pdevices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevices);

    for (pdevices) |pdevice| {
        if (try getDeviceCandidate(pdevice, instance, surface, allocator)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevices;
}

fn getDeviceCandidate(
    pdevice: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !?DeviceCandidate {
    if (!try checkDeviceExtensionSupport(pdevice, instance, allocator)) return null;

    if (!try checkDeviceSurfaceSupport(pdevice, instance, surface)) return null;

    if (try findQueueFamilies(pdevice, instance, surface, allocator)) |queue_families| {
        const props = instance.getPhysicalDeviceProperties(pdevice);
        return DeviceCandidate{
            .pdevice = pdevice,
            .props = props,
            .queues = queue_families,
        };
    }

    return null;
}

fn checkDeviceExtensionSupport(
    pdevice: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    allocator: std.mem.Allocator,
) !bool {
    const properties_list = try instance.enumerateDeviceExtensionPropertiesAlloc(pdevice, null, allocator);
    defer allocator.free(properties_list);

    const required_device_extensions = comptime getRequiredDeviceExtensions();

    for (required_device_extensions) |required_extension| {
        for (properties_list) |props| {
            if (std.mem.eql(u8, std.mem.span(required_extension), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

const REQUIRED_DEVICE_EXTS = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
fn getRequiredDeviceExtensions() []const [*:0]const u8 {
    return switch (builtin.mode) {
        else => return &REQUIRED_DEVICE_EXTS,
    };
}

fn checkDeviceSurfaceSupport(
    pdevice: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,
) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdevice, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdevice, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn findQueueFamilies(
    pdevice: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !?QueueFamilyIndices {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdevice, allocator);
    defer allocator.free(families);

    var graphics_family_index: ?u32 = null;
    var present_family_index: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family_index == null and properties.queue_flags.graphics_bit) {
            graphics_family_index = family;
        }

        if (present_family_index == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdevice, family, surface)) == .true) {
            present_family_index = family;
        }
    }

    if (graphics_family_index != null and present_family_index != null) {
        return QueueFamilyIndices{
            .graphics_family_index = graphics_family_index.?,
            .present_family_index = present_family_index.?,
        };
    }

    return null;
}

fn initSwapchain() void {}
fn initCommands() void {}
fn initSyncStructures() void {}
