const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const GpuAllocator = @import("GpuAllocator.zig");

const Buffer = @This();

handle: vk.Buffer,
memory: vk.DeviceMemory,
device_address: vk.DeviceAddress,

/// Method that returns a Buffer struct containing the VkBuffer and VkDeviceMemory objects. Asserts usage and flag BDA bit are same truth value
// TODO: possibly improve API by taking bda as a bool to enable it or not
// can simplify GpuArenaAllocator as well if we take bda enabled as a bool
pub fn init(device: *const Device, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, flags: vk.MemoryAllocateFlags, gpu_alloc: GpuAllocator) !Buffer {
    std.debug.assert(usage.shader_device_address_bit == flags.device_address_bit);
    const buffer = try device.proxy.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.proxy.destroyBuffer(buffer, null);
    const mem_reqs = device.proxy.getBufferMemoryRequirements(buffer);
    const mem = try gpu_alloc.allocate(mem_reqs, properties, flags);
    errdefer device.proxy.freeMemory(mem, null);
    try device.proxy.bindBufferMemory(buffer, mem, 0);
    // Vulkan defines the integer value of 0 to be null (as everyone would hopefully expect!).
    const device_address = if (usage.shader_device_address_bit and flags.device_address_bit) device.proxy.getBufferDeviceAddress(&.{ .buffer = buffer }) else 0;
    return .{
        .handle = buffer,
        .memory = mem,
        .device_address = device_address,
    };
}

pub fn deinit(self: *const Buffer, device: *const Device) void {
    device.proxy.destroyBuffer(self.handle, null);
    device.proxy.freeMemory(self.memory, null);
}

/// Takes objects of type T and copys them into the provided buffer
pub fn uploadTo(src: Buffer, comptime T: type, objects: []const T, device: *const Device) !void {
    const data = try device.proxy.mapMemory(src.memory, 0, vk.WHOLE_SIZE, .{});
    defer device.proxy.unmapMemory(src.memory);

    const gpu_objects: [*]T = @ptrCast(@alignCast(data));
    @memcpy(gpu_objects, objects[0..]);
}

pub fn copyTo(src: Buffer, dst: Buffer, size: vk.DeviceSize, device: *const Device, command_pool: vk.CommandPool) !void {
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
