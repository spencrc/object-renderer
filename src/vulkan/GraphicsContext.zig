const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");
const math = @import("math.zig");
const Instance = @import("Instance.zig");
const Vertex = @import("vertex.zig");
const Swapchain = @import("Swapchain.zig");
const Buffer = @import("Buffer.zig");
const Device = @import("Device.zig");
const GpuAllocator = @import("GpuAllocator.zig");
const GraphicsPipeline = @import("GraphicsPipeline.zig");

const max_frames_in_flight = 2;
const vertices = [_]Vertex{
    .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, -0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 0, 1 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 1, 1, 1 } },
};
const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

const FrameResources = struct {
    command_pool: vk.CommandPool, // per frame resource command pool = faster command buffer reset
    command_buffer: vk.CommandBuffer,
    image_acquired_semaphore: vk.Semaphore, // used to block rendering until able to present (go-ahead from GPU)
};

const UniformBufferObject = struct {
    model: math.Mat4,
    view: math.Mat4,
    proj: math.Mat4,
};

const GraphicsContext = @This();

gpa: std.mem.Allocator,
instance: *const Instance,
surface: vk.SurfaceKHR,

device: Device,

swapchain: Swapchain,

pipeline: GraphicsPipeline,

timeline_semaphore: vk.Semaphore,
frame_resources: [max_frames_in_flight]FrameResources,

vertex_buffer: Buffer,
index_buffer: Buffer,

recreate_swapchain: bool = false,
next_frame_index: u32 = 0,
next_signal_value: u64 = max_frames_in_flight + 1,

pub fn init(
    instance: *const Instance,
    surface: vk.SurfaceKHR,
    screen_width: usize,
    screen_height: usize,
    gpa: std.mem.Allocator,
) !GraphicsContext {
    errdefer instance.proxy.destroySurfaceKHR(surface, null);

    const device: Device = try .init(instance, surface, gpa);
    errdefer device.deinit(gpa);

    const gpu_alloc: GpuAllocator = .init(&device);

    var swapchain: Swapchain = try .init(&device, instance, surface, screen_width, screen_height, gpa, gpu_alloc);
    errdefer swapchain.deinit(&device);

    const pipeline: GraphicsPipeline = try .init(&device, swapchain.surface_format.format);
    errdefer pipeline.deinit(&device);

    const semaphore_type_info = vk.SemaphoreTypeCreateInfo{
        .semaphore_type = .timeline,
        .initial_value = max_frames_in_flight,
    };
    const timeline_semaphore = try device.proxy.createSemaphore(&.{
        .p_next = &semaphore_type_info,
    }, null);
    errdefer device.proxy.destroySemaphore(timeline_semaphore, null);

    const frame_resources = try initFrameResources(&device);
    errdefer deinitFrameResources(&device, frame_resources);

    const command_pool = try device.proxy.createCommandPool(&.{
        .queue_family_index = device.graphics_queue.index, // TODO: use transfer family
    }, null);
    defer device.proxy.destroyCommandPool(command_pool, null);

    const vertex_buffer: Buffer = try .init(
        &device,
        @sizeOf(@TypeOf(vertices)),
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
        gpu_alloc,
    );
    errdefer vertex_buffer.deinit(&device);
    try vertex_buffer.uploadTo(&device, command_pool, Vertex, &vertices, gpu_alloc);

    const index_buffer: Buffer = try .init(
        &device,
        @sizeOf(@TypeOf(indices)),
        .{ .transfer_dst_bit = true, .index_buffer_bit = true },
        .{ .device_local_bit = true },
        .{},
        gpu_alloc,
    );
    errdefer index_buffer.deinit(&device);
    try index_buffer.uploadTo(&device, command_pool, u16, &indices, gpu_alloc);

    return .{
        .gpa = gpa,
        .instance = instance,
        .surface = surface,
        .device = device,
        .swapchain = swapchain,
        .pipeline = pipeline,
        .timeline_semaphore = timeline_semaphore,
        .frame_resources = frame_resources,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
    };
}

pub fn deinit(self: *GraphicsContext) void {
    self.device.proxy.deviceWaitIdle() catch @panic("failed to wait for device to idle!");

    self.vertex_buffer.deinit(&self.device);
    self.index_buffer.deinit(&self.device);

    deinitFrameResources(&self.device, self.frame_resources);

    self.device.proxy.destroySemaphore(self.timeline_semaphore, null);

    self.pipeline.deinit(&self.device);

    self.swapchain.deinit(&self.device);

    self.device.deinit(self.gpa);

    self.instance.proxy.destroySurfaceKHR(self.surface, null);
}

/// Initializes array of frame resources for GraphicsContext
fn initFrameResources(device: *const Device) ![max_frames_in_flight]FrameResources {
    var frame_resources: [max_frames_in_flight]FrameResources = undefined;
    for (&frame_resources) |*res| {
        const image_acquired_semaphore = try device.proxy.createSemaphore(&.{}, null);
        errdefer device.proxy.destroySemaphore(image_acquired_semaphore, null);

        const command_pool = try device.proxy.createCommandPool(&.{
            .queue_family_index = device.graphics_queue.index,
        }, null);
        errdefer device.proxy.destroyCommandPool(command_pool, null);

        var command_buffer: vk.CommandBuffer = undefined;
        try device.proxy.allocateCommandBuffers(&.{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer));

        res.* = .{
            .image_acquired_semaphore = image_acquired_semaphore,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
        };
    }
    return frame_resources;
}

fn deinitFrameResources(device: *const Device, frame_resources: [max_frames_in_flight]FrameResources) void {
    for (frame_resources) |res| {
        device.proxy.freeCommandBuffers(res.command_pool, &.{res.command_buffer});
        device.proxy.destroyCommandPool(res.command_pool, null);
        device.proxy.destroySemaphore(res.image_acquired_semaphore, null);
    }
}

/// To be called inside application loop to actually draw!
pub fn render(self: *GraphicsContext, screen_width: usize, screen_height: usize) !void {
    const device = self.device.proxy;

    if (self.recreate_swapchain) {
        try self.swapchain.recreate(&self.device, self.instance, self.surface, screen_width, screen_height);
        self.recreate_swapchain = false;
    }

    const frame_resource_index: u32 = self.next_frame_index;
    self.next_frame_index = (self.next_frame_index + 1) % max_frames_in_flight;

    const signal_value: u64 = self.next_signal_value;
    self.next_signal_value += 1;

    const wait_value: u64 = signal_value - max_frames_in_flight;

    _ = try device.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = &[_]vk.Semaphore{self.timeline_semaphore},
        .p_values = &[_]u64{wait_value},
    }, std.math.maxInt(u64));
    // Q: for the first two frames, what happens? don't they have nothing to wait on?
    // A: actually, they do! the signal will be for the third frame for the first frame.
    // then, the third frame will re-use the first frame's resources as its wait value will be 3.

    const res = self.frame_resources[frame_resource_index];
    try device.resetCommandPool(res.command_pool, .{});

    const swapchain_width = self.swapchain.extent.width;
    const swapchain_height = self.swapchain.extent.height;

    const acquire_result = device.acquireNextImageKHR(self.swapchain.handle, std.math.maxInt(u64), res.image_acquired_semaphore, .null_handle) catch |err| switch (err) {
        error.OutOfDateKHR => {
            self.recreate_swapchain = true;
            return;
        },
        else => return err,
    };
    self.recreate_swapchain = switch (acquire_result.result) {
        .suboptimal_khr => true,
        .success => swapchain_width != screen_width or swapchain_height != screen_height,
        else => return error.CannotAcquireSwapchainImage,
    };

    const image_index = acquire_result.image_index;

    // begin recording commands
    try device.beginCommandBuffer(res.command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    // barriers establish dependencies for stages in the Vulkan pipeline
    const layout_barriers = [_]vk.ImageMemoryBarrier2{
        .{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{}, // don't care if we're blocking reads or writes
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true }, // writes allowed when transition done
            .old_layout = .undefined,
            .new_layout = .color_attachment_optimal,
            .image = self.swapchain.swap_images[image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0, // swapchain image, no sampling will be done.
                .level_count = 1,
                .base_array_layer = 0, // swapchain image, there's just 1 image.
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        },
        .{
            .src_stage_mask = .{ .early_fragment_tests_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
            .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .depth_attachment_optimal,
            .image = self.swapchain.depth_image,
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        },
    };
    device.cmdPipelineBarrier2(res.command_buffer, &.{
        .image_memory_barrier_count = layout_barriers.len,
        .p_image_memory_barriers = &layout_barriers,
    });

    // setup attachments (color and depth) and begin dynamic rendering
    const color_attach_info = vk.RenderingAttachmentInfo{
        .image_view = self.swapchain.swap_image_views[image_index],
        .image_layout = .color_attachment_optimal,
        .load_op = .clear, // clear the image on load
        .store_op = .store, // keep data for presentation
        .clear_value = .{ .color = .{ .float_32 = .{ 0.1, 0.1, 0.1, 1.0 } } },
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
    };
    const depth_attach_info = vk.RenderingAttachmentInfo{
        .image_view = self.swapchain.depth_image_view,
        .image_layout = .depth_attachment_optimal,
        .load_op = .clear,
        .store_op = .dont_care,
        .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0.0 } },
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
    };
    const rendering_info = vk.RenderingInfo{
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = swapchain_width, .height = swapchain_height },
        },
        .layer_count = 1,
        .color_attachment_count = 1,
        .p_color_attachments = &[_]vk.RenderingAttachmentInfo{color_attach_info},
        .p_depth_attachment = &depth_attach_info,
        .view_mask = 0,
    };

    // record dynamic rendering commands
    device.cmdBeginRendering(res.command_buffer, &rendering_info);
    {
        const viewport = vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(swapchain_width),
            .height = @floatFromInt(swapchain_height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };
        device.cmdSetViewport(res.command_buffer, 0, &[_]vk.Viewport{viewport});

        // scissor test allows discarding areas outside of display region
        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = swapchain_width, .height = swapchain_height },
        };
        device.cmdSetScissor(res.command_buffer, 0, &[_]vk.Rect2D{scissor});

        const screen_width_f32: f32 = @floatFromInt(screen_width);
        const screen_height_f32: f32 = @floatFromInt(screen_height);
        var proj: math.Mat4 = .persp(75, screen_width_f32 / screen_height_f32, 0.1, 10);
        proj.m[1][1] *= -1;
        const push_data = GraphicsPipeline.PushConstants{
            .vertex_buffer_address = self.vertex_buffer.device_address,
            .model = .rotate(90, math.Vec3{ .x = 0, .y = 0, .z = 1 }),
            .view = .lookat(math.Vec3{ .x = 2, .y = 2, .z = 2 }, math.Vec3{ .x = 0, .y = 0, .z = 0 }, math.Vec3{ .x = 0, .y = 0, .z = 1 }),
            .proj = proj,
        };
        device.cmdPushConstants(
            res.command_buffer,
            self.pipeline.pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(GraphicsPipeline.PushConstants),
            @ptrCast(&push_data),
        );

        device.cmdBindPipeline(res.command_buffer, .graphics, self.pipeline.handle);
        device.cmdBindIndexBuffer(res.command_buffer, self.index_buffer.handle, 0, .uint16);
        device.cmdDrawIndexed(res.command_buffer, indices.len, 1, 0, 0, 0);
    }
    device.cmdEndRendering(res.command_buffer);

    // transition image from color attachment to presentation
    const present_layout_barriers = [_]vk.ImageMemoryBarrier2{
        .{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_stage_mask = .{}, // none. cache is flushed & layout transitioned
            .dst_access_mask = .{},
            .old_layout = .color_attachment_optimal,
            .new_layout = .present_src_khr,
            .image = self.swapchain.swap_images[image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        },
    };
    device.cmdPipelineBarrier2(res.command_buffer, &.{
        .image_memory_barrier_count = present_layout_barriers.len,
        .p_image_memory_barriers = &present_layout_barriers,
    });

    try device.endCommandBuffer(res.command_buffer);

    // ensure swapchain image is actually viable to start colour output
    const image_acquire_wait_info = vk.SemaphoreSubmitInfo{
        .semaphore = res.image_acquired_semaphore,
        .value = 0, // ignored since it's not a timeline semaphore
        .stage_mask = .{ .color_attachment_output_bit = true }, // wait before drawing to image
        .device_index = 0,
    };
    // signal the image can be presented
    const semaphore_signals = [_]vk.SemaphoreSubmitInfo{
        .{ // render work completion signal
            .semaphore = self.swapchain.render_complete_semaphores[image_index],
            .value = 0,
            .stage_mask = .{ .all_graphics_bit = true },
            .device_index = 0,
        },
        .{ // entire frame completed (timeline)
            .semaphore = self.timeline_semaphore,
            .value = signal_value,
            .stage_mask = .{ .all_commands_bit = true },
            .device_index = 0,
        },
    };
    const cmd_submit_info = vk.CommandBufferSubmitInfo{
        .command_buffer = res.command_buffer,
        .device_mask = 0,
    };
    const submit_info = vk.SubmitInfo2{
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = &[_]vk.SemaphoreSubmitInfo{image_acquire_wait_info},
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &[_]vk.CommandBufferSubmitInfo{cmd_submit_info},
        .signal_semaphore_info_count = semaphore_signals.len,
        .p_signal_semaphore_infos = &semaphore_signals,
    };
    try device.queueSubmit2(self.device.graphics_queue.handle, &[_]vk.SubmitInfo2{submit_info}, .null_handle);

    // present the image
    const present_result = device.queuePresentKHR(self.device.present_queue.handle, &vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &[_]vk.Semaphore{self.swapchain.render_complete_semaphores[image_index]},
        .swapchain_count = 1,
        .p_swapchains = &[_]vk.SwapchainKHR{self.swapchain.handle},
        .p_image_indices = &[_]u32{image_index},
    }) catch |err| switch (err) {
        error.OutOfDateKHR => {
            self.recreate_swapchain = true;
            return;
        },
        else => return err,
    };
    self.recreate_swapchain = switch (present_result) {
        .suboptimal_khr => true,
        .success => self.recreate_swapchain,
        else => unreachable,
    };
}
