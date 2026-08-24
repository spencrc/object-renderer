const vk = @import("vulkan");
const std = @import("std");
const GraphicsContext = @import("graphics_context.zig");

pub const depth_format = vk.Format.d32_sfloat;

const Swapchain = @This();

gpa: std.mem.Allocator,

handle: vk.SwapchainKHR,
surface_format: vk.SurfaceFormatKHR,
extent: vk.Extent2D,
swap_image_views: []vk.ImageView,
render_complete_semaphores: []vk.Semaphore,
depth_image: vk.Image,
depth_image_mem: vk.DeviceMemory,
depth_image_view: vk.ImageView,

/// Initializes swapchain with correct surface format, extent, and present mode for GraphicsContext
pub fn init(gc: *const GraphicsContext, screen_width: usize, screen_height: usize, gpa: std.mem.Allocator) !Swapchain {
    return initRecycle(gc, screen_width, screen_height, gpa, .null_handle);
}

fn initRecycle(gc: *const GraphicsContext, screen_width: usize, screen_height: usize, gpa: std.mem.Allocator, old_handle: vk.SwapchainKHR) !Swapchain {
    defer if (old_handle != .null_handle) {
        gc.device.destroySwapchainKHR(old_handle, null);
    };

    const caps = try gc.instance.proxy.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdevice, gc.surface);
    const actual_extent = findSwapExtent(caps, screen_width, screen_height);
    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const surface_format = try findSurfaceFormat(gc.instance.proxy, gc.pdevice, gc.surface, gpa);
    const present_mode = try findPresentMode(gc.instance.proxy, gc.pdevice, gc.surface, gpa);

    const image_count = if (caps.max_image_count > 0)
        @min(caps.min_image_count, caps.max_image_count)
    else
        caps.min_image_count;

    const queue_family_index = [_]u32{ gc.graphics_family_index, gc.present_family_index };
    const sharing_mode: vk.SharingMode = if (gc.graphics_family_index != gc.present_family_index)
        .concurrent
    else
        .exclusive;

    const swapchain = try gc.device.createSwapchainKHR(&.{
        .surface = gc.surface,
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
    errdefer gc.device.destroySwapchainKHR(swapchain, null);

    const images = try gc.device.getSwapchainImagesAllocKHR(swapchain, gpa);
    defer gpa.free(images);

    const image_views = try gpa.alloc(vk.ImageView, images.len);
    errdefer gpa.free(image_views);

    const render_complete_semaphores = try gpa.alloc(vk.Semaphore, images.len);
    errdefer gpa.free(render_complete_semaphores);

    var i: usize = 0;
    errdefer for (image_views[0..i]) |iv| gc.device.destroyImageView(iv, null);
    errdefer for (render_complete_semaphores[0..i]) |rcs| gc.device.destroySemaphore(rcs, null);

    for (images) |image| {
        image_views[i] = try gc.device.createImageView(&.{
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

        render_complete_semaphores[i] = try gc.device.createSemaphore(&.{}, null);

        i += 1;
    }

    const depth_image = try gc.device.createImage(&.{
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
    errdefer gc.device.destroyImage(depth_image, null);
    const image_mem_reqs = gc.device.getImageMemoryRequirements(depth_image);
    const image_mem = try gc.allocate(image_mem_reqs, .{ .device_local_bit = true });
    errdefer gc.device.freeMemory(image_mem, null);
    try gc.device.bindImageMemory(depth_image, image_mem, 0);

    const depth_image_view = try gc.device.createImageView(&.{
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
    errdefer gc.device.destroyImageView(depth_image_view, null);

    return Swapchain{
        .gpa = gpa,
        .surface_format = surface_format,
        .extent = actual_extent,
        .handle = swapchain,
        .swap_image_views = image_views,
        .render_complete_semaphores = render_complete_semaphores,
        .depth_image = depth_image,
        .depth_image_mem = image_mem,
        .depth_image_view = depth_image_view,
    };
}

pub fn recreate(self: *Swapchain, gc: *const GraphicsContext, screen_width: usize, screen_height: usize) !void {
    const gpa = self.gpa;
    const old_handle = self.handle;

    try gc.device.deviceWaitIdle();

    self.deinitExceptSwapchain(gc);

    // set current handle to NULL_HANDLE to signal that the current swapchain does no longer need to be
    // de-initialized if we fail to recreate it.
    self.handle = .null_handle;
    self.* = try initRecycle(gc, screen_width, screen_height, gpa, old_handle);
}

fn deinitExceptSwapchain(self: *Swapchain, gc: *const GraphicsContext) void {
    gc.device.destroyImageView(self.depth_image_view, null);
    gc.device.freeMemory(self.depth_image_mem, null);
    gc.device.destroyImage(self.depth_image, null);
    for (self.render_complete_semaphores) |s| gc.device.destroySemaphore(s, null);
    self.gpa.free(self.render_complete_semaphores);
    for (self.swap_image_views) |si| gc.device.destroyImageView(si, null);
    self.gpa.free(self.swap_image_views);
}

pub fn deinit(self: *Swapchain, gc: *const GraphicsContext) void {
    self.deinitExceptSwapchain(gc);
    gc.device.destroySwapchainKHR(self.handle, null);
}

fn findSurfaceFormat(
    instance: vk.InstanceProxy,
    pdevice: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !vk.SurfaceFormatKHR {
    const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdevice, surface, allocator);
    defer allocator.free(surface_formats);

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
    allocator: std.mem.Allocator,
) !vk.PresentModeKHR {
    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdevice, surface, allocator);
    defer allocator.free(present_modes);

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
