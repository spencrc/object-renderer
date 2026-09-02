const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const GpuAllocator = @import("GpuAllocator.zig");

const Buffer = @This();

handle: vk.Buffer,
memory: vk.DeviceMemory,

/// Method that returns a Buffer struct containing the VkBuffer and VkDeviceMemory objects
pub fn init(device: *const Device, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, gpu_alloc: GpuAllocator) !Buffer {
    const buffer = try device.proxy.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.proxy.destroyBuffer(buffer, null);
    const mem_reqs = device.proxy.getBufferMemoryRequirements(buffer);
    const mem = try gpu_alloc.allocate(mem_reqs, properties);
    errdefer device.proxy.freeMemory(mem, null);
    try device.proxy.bindBufferMemory(buffer, mem, 0);
    return .{
        .handle = buffer,
        .memory = mem,
    };
}

pub fn deinit(self: Buffer, device: *const Device) void {
    device.proxy.freeMemory(self.memory, null);
    device.proxy.destroyBuffer(self.handle, null);
}

/// Takes objects of type T and copys them into the provided buffer
pub fn uploadTo(dst: Buffer, device: *const Device, command_pool: vk.CommandPool, comptime T: type, objects: []const T, gpu_alloc: GpuAllocator) !void {
    const size = @sizeOf(T) * objects.len;
    const staging_buffer: Buffer = try .init(
        device,
        size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        gpu_alloc,
    );
    errdefer staging_buffer.deinit(device);

    {
        const data = try device.proxy.mapMemory(staging_buffer.memory, 0, vk.WHOLE_SIZE, .{});
        defer device.proxy.unmapMemory(staging_buffer.memory);

        const gpu_objects: [*]T = @ptrCast(@alignCast(data));
        @memcpy(gpu_objects, objects[0..]);
    }

    try copyBuffer(device, command_pool, staging_buffer, dst, size);
}

fn copyBuffer(device: *const Device, command_pool: vk.CommandPool, src: Buffer, dst: Buffer, size: vk.DeviceSize) !void {
    var command_buffer: vk.CommandBuffer = undefined;
    try device.proxy.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer));
    defer device.proxy.freeCommandBuffers(command_pool, &.{command_buffer});

    try device.proxy.beginCommandBuffer(command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const copy_region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    device.proxy.cmdCopyBuffer(command_buffer, src.handle, dst.handle, &.{copy_region});

    try device.proxy.endCommandBuffer(command_buffer);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = &.{command_buffer},
        .p_wait_dst_stage_mask = undefined,
    };
    // TODO: use transfer queue or pass queue as param
    try device.proxy.queueSubmit(device.graphics_queue.handle, &.{submit_info}, .null_handle);
    try device.proxy.queueWaitIdle(device.graphics_queue.handle);
}
