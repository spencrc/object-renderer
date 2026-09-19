const vk = @import("vulkan");
const std = @import("std");
const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const VkPoolAlloc = @import("mem/PoolAllocator.zig");
// const GpuAllocator = @import("GpuAllocator.zig");

pub const depth_format = vk.Format.d32_sfloat;

const Swapchain = @This();

gpa: std.mem.Allocator,
swapchain_arena: VkPoolAlloc,
// gpu_alloc: GpuAllocator,

handle: vk.SwapchainKHR,
surface_format: vk.SurfaceFormatKHR,
extent: vk.Extent2D,
swap_images: []vk.Image,
swap_image_views: []vk.ImageView,
render_complete_semaphores: []vk.Semaphore,
depth_image: vk.Image,
// depth_image_mem: vk.DeviceMemory,
depth_image_view: vk.ImageView,

/// Initializes swapchain with correct surface format, extent, and present mode for Renderer
pub fn init(
    device: *const Device,
    instance: *const Instance,
    surface: vk.SurfaceKHR,
    screen_width: usize,
    screen_height: usize,
    gpa: std.mem.Allocator,
    // gpu_alloc: GpuAllocator,
) !Swapchain {
    const mem_props = instance.proxy.getPhysicalDeviceMemoryProperties(device.pdevice);
    const swapchain_arena: VkPoolAlloc = try .init(&.{
        .device = device.proxy,
        .memory_properties = mem_props,
        .block_size = 48 * 1024 * 1024, // 48MB
    }, gpa);
    return initRecycle(
        device,
        instance,
        surface,
        screen_width,
        screen_height,
        gpa,
        swapchain_arena,
        // gpu_alloc,
        .null_handle,
    );
}

// TODO: use some kind of create info / opts struct to pass in all these vars
fn initRecycle(
    device: *const Device,
    instance: *const Instance,
    surface: vk.SurfaceKHR,
    screen_width: usize,
    screen_height: usize,
    gpa: std.mem.Allocator,
    // gpu_alloc: GpuAllocator,
    swapchain_arena: VkPoolAlloc,
    old_handle: vk.SwapchainKHR,
) !Swapchain {
    const caps = try instance.proxy.getPhysicalDeviceSurfaceCapabilitiesKHR(device.pdevice, surface);
    const actual_extent = findSwapExtent(caps, screen_width, screen_height);
    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const surface_format = try findSurfaceFormat(instance.proxy, device.pdevice, surface, gpa);
    const present_mode = try findPresentMode(instance.proxy, device.pdevice, surface, gpa);

    const image_count = if (caps.max_image_count > 0)
        @min(caps.min_image_count, caps.max_image_count)
    else
        caps.min_image_count;

    const queue_family_index = [_]u32{ device.graphics_queue.index, device.present_queue.index };
    const sharing_mode: vk.SharingMode = if (device.graphics_queue.index != device.present_queue.index)
        .concurrent
    else
        .exclusive;

    const swapchain = try device.proxy.createSwapchainKHR(&.{
        .surface = surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .queue_family_index_count = queue_family_index.len,
        .p_queue_family_indices = &queue_family_index,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
        .old_swapchain = old_handle,
    }, null);
    errdefer device.proxy.destroySwapchainKHR(swapchain, null);

    const images = try device.proxy.getSwapchainImagesAllocKHR(swapchain, gpa);
    defer gpa.free(images);

    const swap_images = try gpa.alloc(vk.Image, images.len);
    errdefer gpa.free(swap_images);

    const swap_image_views = try gpa.alloc(vk.ImageView, images.len);
    errdefer gpa.free(swap_image_views);

    const render_complete_semaphores = try gpa.alloc(vk.Semaphore, images.len);
    errdefer gpa.free(render_complete_semaphores);

    var i: usize = 0;
    errdefer for (swap_image_views[0..i]) |siv| device.proxy.destroyImageView(siv, null);
    errdefer for (render_complete_semaphores[0..i]) |rcs| device.proxy.destroySemaphore(rcs, null);

    for (images) |image| {
        swap_images[i] = image;

        swap_image_views[i] = try device.proxy.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        render_complete_semaphores[i] = try device.proxy.createSemaphore(&.{}, null);

        i += 1;
    }

    const depth_image = try device.proxy.createImage(&.{
        .image_type = .@"2d",
        .format = depth_format,
        .extent = .{ .width = actual_extent.width, .height = actual_extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .initial_layout = .undefined,
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.proxy.destroyImage(depth_image, null);
    const image_mem_reqs = device.proxy.getImageMemoryRequirements(depth_image);
    const image_alloc = try swapchain_arena.allocate(&.{
        .requirements = image_mem_reqs,
        .properties = .{ .device_local_bit = true },
        .kind = .nonlinear,
    }, gpa);
    try device.proxy.bindImageMemory(depth_image, image_alloc.handle, image_alloc.offset);
    // const image_mem = try gpu_alloc.allocate(image_mem_reqs, .{ .device_local_bit = true }, .{});
    // errdefer device.proxy.freeMemory(image_mem, null);
    // try device.proxy.bindImageMemory(depth_image, image_mem, 0);

    const depth_image_view = try device.proxy.createImageView(&.{
        .image = depth_image,
        .view_type = .@"2d",
        .format = depth_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);
    errdefer device.proxy.destroyImageView(depth_image_view, null);

    return Swapchain{
        .gpa = gpa,
        .swapchain_arena = swapchain_arena,
        // .gpu_alloc = gpu_alloc,
        .surface_format = surface_format,
        .extent = actual_extent,
        .handle = swapchain,
        .swap_images = swap_images,
        .swap_image_views = swap_image_views,
        .render_complete_semaphores = render_complete_semaphores,
        .depth_image = depth_image,
        // .depth_image_mem = image_mem,
        .depth_image_view = depth_image_view,
    };
}

const tracy = @import("tracy");
const Zone = tracy.Zone;

pub fn recreate(self: *Swapchain, device: *const Device, instance: *const Instance, surface: vk.SurfaceKHR, screen_width: usize, screen_height: usize) !void {
    const zone = Zone.begin(.{ .name = "swapchain", .src = @src() });
    defer zone.end();

    const gpa = self.gpa;
    const swapchain_arena = self.swapchain_arena;
    // const gpu_alloc = self.gpu_alloc;
    const old_handle = self.handle;

    try device.proxy.deviceWaitIdle();

    self.swapchain_arena.reset();
    const new: Swapchain = try initRecycle(device, instance, surface, screen_width, screen_height, gpa, swapchain_arena, old_handle);
    // const new: Swapchain = try initRecycle(device, instance, surface, screen_width, screen_height, gpa, gpu_alloc, old_handle);

    self.deinitExceptSwapchain(device);

    if (old_handle != .null_handle) {
        device.proxy.destroySwapchainKHR(old_handle, null);
    }

    // set current handle to NULL_HANDLE to signal that the current swapchain does no longer need to be
    // de-initialized if we fail to recreate it.
    self.handle = .null_handle;
    self.* = new;
}

fn deinitExceptSwapchain(self: *Swapchain, device: *const Device) void {
    device.proxy.destroyImageView(self.depth_image_view, null);
    // device.proxy.freeMemory(self.depth_image_mem, null);
    device.proxy.destroyImage(self.depth_image, null);
    for (self.render_complete_semaphores) |s| device.proxy.destroySemaphore(s, null);
    self.gpa.free(self.render_complete_semaphores);
    for (self.swap_image_views) |siv| device.proxy.destroyImageView(siv, null);
    self.gpa.free(self.swap_image_views);
    // swap_images owned by swapchain itself, and will be cleaned when swapchain destroyed
    self.gpa.free(self.swap_images);
}

pub fn deinit(self: *Swapchain, device: *const Device) void {
    if (self.handle != .null_handle) self.deinitExceptSwapchain(device);
    self.swapchain_arena.deinit();
    device.proxy.destroySwapchainKHR(self.handle, null);
}

fn findSurfaceFormat(
    instance: vk.InstanceProxy,
    pdevice: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    gpa: std.mem.Allocator,
) !vk.SurfaceFormatKHR {
    const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdevice, surface, gpa);
    defer gpa.free(surface_formats);

    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    for (surface_formats) |format| {
        if (std.meta.eql(format, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

fn findPresentMode(
    instance: vk.InstanceProxy,
    pdevice: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    gpa: std.mem.Allocator,
) !vk.PresentModeKHR {
    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdevice, surface, gpa);
    defer gpa.free(present_modes);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr; // Guaranteed to be available
}

fn findSwapExtent(caps: vk.SurfaceCapabilitiesKHR, screen_width: usize, screen_height: usize) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        const actual_width: u32 = @intCast(screen_width);
        const actual_height: u32 = @intCast(screen_height);
        return .{
            .width = std.math.clamp(actual_width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(actual_height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}
