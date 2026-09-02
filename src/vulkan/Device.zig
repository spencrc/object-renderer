const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");

const Device = @This();

const QueueFamilyIndices = struct {
    graphics_family_index: u32,
    present_family_index: u32,
};

const Queue = struct {
    handle: vk.Queue,
    index: u32,

    fn init(device_proxy: vk.DeviceProxy, family: u32) Queue {
        return .{
            .handle = device_proxy.getDeviceQueue(family, 0),
            .index = family,
        };
    }
};

// TODO: make physical device initialization its own file/struct since it's independent anyways
const DeviceCandidate = struct {
    pdevice: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queue_indices: QueueFamilyIndices,
};

const RequiredFeatures = struct {
    feats14: vk.PhysicalDeviceVulkan14Features = .{},
    feats13: vk.PhysicalDeviceVulkan13Features = .{
        .synchronization_2 = .true,
        .dynamic_rendering = .true,
    },
    feats12: vk.PhysicalDeviceVulkan12Features = .{
        .timeline_semaphore = .true,
    },

    fn chain(rf: *RequiredFeatures) vk.PhysicalDeviceFeatures2 {
        rf.feats12.p_next = &rf.feats13;
        rf.feats13.p_next = &rf.feats14;
        return .{ .p_next = &rf.feats12, .features = .{} };
    }

    fn isSupported(rf: *const RequiredFeatures) bool {
        return rf.feats13.synchronization_2 == .true and
            rf.feats13.dynamic_rendering == .true and
            rf.feats12.timeline_semaphore == .true;
    }
};

proxy: vk.DeviceProxy,
pdevice: vk.PhysicalDevice,
mem_props: vk.PhysicalDeviceMemoryProperties,
graphics_queue: Queue,
present_queue: Queue, // in theory, provides minor performance boost

/// Initializes device from supported physical device for Graphics Context
pub fn init(instance: *const Instance, surface: vk.SurfaceKHR, gpa: std.mem.Allocator) !Device {
    const candidate = try pickCandidateDevice(instance.proxy, surface, gpa);
    const pdevice = candidate.pdevice;
    // TODO: get transfer family index
    const graphics_family_index = candidate.queue_indices.graphics_family_index;
    const present_family_index = candidate.queue_indices.present_family_index;

    const priority = [_]f32{1};
    var required_features = RequiredFeatures{};
    const feats2 = required_features.chain();
    const required_device_extensions = comptime getRequiredDeviceExtensions();
    const device = try instance.proxy.createDevice(pdevice, &.{
        .p_next = &feats2,
        .queue_create_info_count = if (graphics_family_index == present_family_index) 1 else 2,
        .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = graphics_family_index,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .queue_family_index = present_family_index,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        },
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = required_device_extensions.ptr,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
    }, null);

    const vkd = try gpa.create(vk.DeviceWrapper);
    errdefer gpa.destroy(vkd);
    vkd.* = vk.DeviceWrapper.load(device, instance.proxy.wrapper.dispatch.vkGetDeviceProcAddr.?);
    const proxy = vk.DeviceProxy.init(device, vkd);
    errdefer proxy.destroyDevice(null);

    return .{
        .proxy = proxy,
        .pdevice = pdevice,
        .mem_props = instance.proxy.getPhysicalDeviceMemoryProperties(pdevice),
        .graphics_queue = .init(proxy, graphics_family_index),
        .present_queue = .init(proxy, present_family_index),
    };
}

pub fn deinit(device: Device, gpa: std.mem.Allocator) void {
    // device
    device.proxy.destroyDevice(null);
    // need to destroy wrappers as well to prevent mem leaks
    gpa.destroy(device.proxy.wrapper);
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

    if (!checkDeviceFeaturesSupport(pdevice, instance)) return null;

    if (try findQueueFamilies(pdevice, instance, surface, allocator)) |queue_families| {
        const props = instance.getPhysicalDeviceProperties(pdevice);
        return DeviceCandidate{
            .pdevice = pdevice,
            .props = props,
            .queue_indices = queue_families,
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

const required_device_exts = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
fn getRequiredDeviceExtensions() []const [*:0]const u8 {
    return switch (builtin.mode) {
        else => return &required_device_exts,
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

fn checkDeviceFeaturesSupport(pdevice: vk.PhysicalDevice, instance: vk.InstanceProxy) bool {
    var req = RequiredFeatures{};
    var feats = req.chain();
    instance.getPhysicalDeviceFeatures2(pdevice, &feats);
    return req.isSupported();
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
