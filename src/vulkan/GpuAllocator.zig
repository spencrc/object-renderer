const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");

const GpuAllocator = @This();

device: *const Device,

pub fn init(device: *const Device) GpuAllocator {
    return .{ .device = device };
}

fn findMemoryTypeIndex(self: GpuAllocator, memory_types: u32, flags: vk.MemoryPropertyFlags) !u32 {
    const memory_properties = self.device.mem_props;
    for (memory_properties.memory_types[0..memory_properties.memory_type_count], 0..) |mem_type, i| {
        if (memory_types & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

pub fn allocate(self: GpuAllocator, requirements: vk.MemoryRequirements, properties: vk.MemoryPropertyFlags, flags: vk.MemoryAllocateFlags) !vk.DeviceMemory {
    const allocate_flags_info = vk.MemoryAllocateFlagsInfo{
        .flags = flags,
        .device_mask = 0,
    };
    return try self.device.proxy.allocateMemory(&.{
        .p_next = &allocate_flags_info,
        .allocation_size = requirements.size,
        .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, properties),
    }, null);
}
