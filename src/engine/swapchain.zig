const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");
const Engine = @import("graphics_context.zig");

const Swapchain = @This();

ctx: *const Engine,
allocator: std.mem.Allocator,
handle: vk.SwapchainKHR,

pub fn init(ctx: *const Engine, screen_width: usize, screen_height: usize, allocator: std.mem.Allocator) !Swapchain {
    var self: Swapchain = undefined;
    self.allocator = allocator;
    self.ctx = ctx;

    const caps = try self.ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.ctx.pdevice, self.ctx.surface);
    const actual_extent = findSwapExtent(caps, screen_width, screen_height);
    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const format = try findSurfaceFormat(self.ctx, self.allocator);
    const present_mode = try findPresentMode(self.ctx, self.allocator);

    const image_count = if (caps.max_image_count > 0)
        @min(caps.min_image_count, caps.max_image_count)
    else
        caps.min_image_count;

    const queue_family_index = [_]u32{ self.ctx.graphics_family_index, self.ctx.present_family_index };
    const sharing_mode: vk.SharingMode = if (self.ctx.graphics_family_index != self.ctx.present_family_index)
        .concurrent
    else
        .exclusive;

    const swapchain = try self.ctx.device.createSwapchainKHR(&.{
        .surface = self.ctx.surface,
        .min_image_count = image_count,
        .image_format = format.format,
        .image_color_space = format.color_space,
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
        .old_swapchain = .null_handle,
    }, null);
    errdefer self.ctx.device.destroySwapchainKHR(swapchain, null);
    self.handle = swapchain;

    return self;
}

pub fn deinit(self: *Swapchain) void {
    self.ctx.device.destroySwapchainKHR(self.handle, null);
}

fn findSurfaceFormat(ctx: *const Engine, allocator: std.mem.Allocator) !vk.SurfaceFormatKHR {
    const surface_formats = try ctx.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(ctx.pdevice, ctx.surface, allocator);
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

fn findPresentMode(ctx: *const Engine, allocator: std.mem.Allocator) !vk.PresentModeKHR {
    const present_modes = try ctx.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(ctx.pdevice, ctx.surface, allocator);
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
