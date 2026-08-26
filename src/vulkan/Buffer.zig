const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig");

const Buffer = @This();

handle: vk.Buffer,
memory: vk.DeviceMemory,

/// Method that returns a Buffer struct containing the VkBuffer and VkDeviceMemory objects
pub fn init(gc: *const GraphicsContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags) !Buffer {
    const buffer = try gc.device.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer gc.device.destroyBuffer(buffer, null);
    const mem_reqs = gc.device.getBufferMemoryRequirements(buffer);
    const mem = try gc.allocate(mem_reqs, properties);
    errdefer gc.device.freeMemory(mem, null);
    try gc.device.bindBufferMemory(buffer, mem, 0);
    return .{
        .handle = buffer,
        .memory = mem,
    };
}

pub fn deinit(self: Buffer, gc: *const GraphicsContext) void {
    gc.device.freeMemory(self.memory, null);
    gc.device.destroyBuffer(self.handle, null);
}

/// Takes objects of type T and copys them into the provided buffer
pub fn uploadTo(dst: Buffer, gc: *const GraphicsContext, command_pool: vk.CommandPool, comptime T: type, objects: []const T) !void {
    const size = @sizeOf(T) * objects.len;
    const staging_buffer: Buffer = try .init(
        gc,
        size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    errdefer staging_buffer.deinit(gc);

    {
        const data = try gc.device.mapMemory(staging_buffer.memory, 0, vk.WHOLE_SIZE, .{});
        defer gc.device.unmapMemory(staging_buffer.memory);

        const gpu_objects: [*]T = @ptrCast(@alignCast(data));
        @memcpy(gpu_objects, objects[0..]);
    }

    try copyBuffer(gc, command_pool, staging_buffer, dst, size);
}

fn copyBuffer(gc: *const GraphicsContext, command_pool: vk.CommandPool, src: Buffer, dst: Buffer, size: vk.DeviceSize) !void {
    var command_buffer: vk.CommandBuffer = undefined;
    try gc.device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer));
    defer gc.device.freeCommandBuffers(command_pool, &.{command_buffer});

    try gc.device.beginCommandBuffer(command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const copy_region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    gc.device.cmdCopyBuffer(command_buffer, src.handle, dst.handle, &.{copy_region});

    try gc.device.endCommandBuffer(command_buffer);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = &.{command_buffer},
        .p_wait_dst_stage_mask = undefined,
    };
    // TODO: use transfer queue or pass queue as param
    try gc.device.queueSubmit(gc.graphics_queue, &.{submit_info}, .null_handle);
    try gc.device.queueWaitIdle(gc.graphics_queue);
}
