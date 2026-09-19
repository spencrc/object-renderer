const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");

// 64MB
const block_size = 64 * 1024 * 1024;

const Allocation = struct {
    handle: vk.DeviceMemory,
    size: vk.DeviceSize,
    offset: vk.DeviceSize,
};

const Chunk = struct {
    handle: vk.DeviceMemory,
    size: vk.DeviceSize,
    offset: vk.DeviceSize,
    next: ?*Chunk,
};

const Subpool = struct {
    head: ?*Chunk = null,

    /// Allocates and pushes a Chunk onto the stack.
    fn push(
        sp: *Subpool,
        memory_index_type: u32,
        flags: vk.MemoryAllocateFlags,
        device: vk.DeviceProxy,
        allocator: std.mem.Allocator,
    ) !*Chunk {
        // if there's been a reset we have chunks already good to go
        if (sp.head) |head| {
            if (head.next) |next| {
                std.debug.print("GpuArenaAllocator.zig(push): re-used old chunk!\n", .{});
                sp.head = next;
                return sp.head.?;
            }
        }
        std.debug.print("GpuArenaAllocator.zig(push): allocated new chunk!\n", .{});
        // otherwise, allocate new chunk
        const allocate_flags_info = vk.MemoryAllocateFlagsInfo{
            .flags = flags,
            .device_mask = 0,
        };
        const c = try allocator.create(Chunk);
        errdefer allocator.destroy(c);
        c.* = .{
            .size = block_size,
            .offset = 0,
            .next = sp.head,
            .handle = try device.allocateMemory(&.{
                .p_next = &allocate_flags_info,
                .allocation_size = block_size,
                .memory_type_index = memory_index_type,
            }, null),
        };
        sp.head = c;
        return c;
    }

    /// Pops a Chunk off the stack and frees them. Asserts head is not null
    fn pop(sp: *Subpool, allocator: std.mem.Allocator) void {
        std.debug.assert(sp.head != null);
        const temp = sp.head.?;
        sp.head = sp.head.?.next;
        allocator.destroy(temp);
    }

    /// Frees all Chunks pushed onto the stack
    fn free(sp: *Subpool, device: vk.DeviceProxy, allocator: std.mem.Allocator) void {
        while (sp.head != null) {
            const c = sp.peek().?;
            device.freeMemory(c.handle, null);
            sp.pop(allocator);
        }
    }

    /// Resets the offsets for all chunks pushed onto the stack, then sets the bottom of the stack as the head
    fn reset(sp: *Subpool) void {
        var cur = sp.peek();
        while (cur != null) {
            cur.?.offset = 0;
            cur = cur.?.next;
        }
    }

    fn peek(sp: *Subpool) ?*Chunk {
        return sp.head;
    }
};

const Pool = struct {
    linear_subpool: Subpool,
    nonlinear_subpool: Subpool,
    bda_subpool: Subpool,
};

const GpuAllocator = @This();

device: vk.DeviceProxy,
memory_properties: vk.PhysicalDeviceMemoryProperties,
pools: []Pool,
gpa: std.mem.Allocator,

pub fn init(device: vk.DeviceProxy, memory_properties: vk.PhysicalDeviceMemoryProperties, gpa: std.mem.Allocator) !GpuAllocator {
    const pools = try gpa.alloc(Pool, memory_properties.memory_type_count);
    for (pools) |*p| {
        p.bda_subpool = .{};
        p.linear_subpool = .{};
        p.nonlinear_subpool = .{};
    }
    return .{
        .device = device,
        .memory_properties = memory_properties,
        .pools = pools,
        .gpa = gpa,
    };
}

pub fn deinit(self: *const GpuAllocator) void {
    for (self.pools) |*p| {
        p.bda_subpool.free(self.device, self.gpa);
        p.linear_subpool.free(self.device, self.gpa);
        p.nonlinear_subpool.free(self.device, self.gpa);
    }
    self.gpa.free(self.pools);
}

pub fn reset(self: *const GpuAllocator) void {
    for (self.pools) |*p| {
        p.bda_subpool.reset();
        p.linear_subpool.reset();
        p.nonlinear_subpool.reset();
    }
}

pub fn allocate_buffer(self: GpuAllocator, requirements: vk.MemoryRequirements, properties: vk.MemoryPropertyFlags, flags: vk.MemoryAllocateFlags) !vk.DeviceMemory {
    return allocate(self, requirements, properties, flags, true);
}

pub fn allocate_image(
    self: GpuAllocator,
    requirements: vk.MemoryRequirements,
    properties: vk.MemoryPropertyFlags,
    tiling: vk.ImageTiling,
) !Allocation {
    return allocate(self, requirements, properties, .{}, tiling == .optimal or tiling == .drm_format_modifier_ext);
}

// linear boolean determined by public-facing allocate_buffer or allocate_image functions
fn allocate(self: GpuAllocator, requirements: vk.MemoryRequirements, properties: vk.MemoryPropertyFlags, flags: vk.MemoryAllocateFlags, linear: bool) !Allocation {
    std.debug.assert(requirements.size <= block_size);
    const memory_index_type = try self.findMemoryTypeIndex(requirements.memory_type_bits, properties);
    // need to directly access subpool struct, thus take ptr to it
    const pool: *Subpool = if (linear and flags.device_address_bit)
        &self.pools[memory_index_type].bda_subpool
    else if (linear)
        &self.pools[memory_index_type].linear_subpool
    else
        &self.pools[memory_index_type].nonlinear_subpool;

    var head: *Chunk = if (pool.peek()) |head|
        head
    else
        try pool.push(memory_index_type, flags, self.device, self.gpa);

    // add padding to the current offset to ensure alignment
    var start_offset = compute_padding(head.offset, requirements.alignment);
    // NOW we check if we can add, after calculating the aligned offset
    if (start_offset + requirements.size > head.size) {
        head = try pool.push(memory_index_type, flags, self.device, self.gpa);
        start_offset = 0;
    }
    head.offset = start_offset + requirements.size;
    return Allocation{
        .handle = head.handle,
        .size = requirements.size,
        .offset = start_offset,
    };
}

fn findMemoryTypeIndex(self: GpuAllocator, memory_types: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.memory_properties.memory_types[0..self.memory_properties.memory_type_count], 0..) |mem_type, i| {
        if (memory_types & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

fn compute_padding(offset: vk.DeviceSize, alignment: u64) vk.DeviceSize {
    std.debug.assert(alignment != 0 and (alignment & (alignment - 1)) == 0);
    return (offset + (alignment - 1)) & ~(alignment - 1);
}
