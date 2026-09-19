const std = @import("std");
const vk = @import("vulkan");

const PoolAllocator = @This();

device: vk.DeviceProxy,
memory_properties: vk.PhysicalDeviceMemoryProperties,
block_size: vk.DeviceSize,
pools: []Pool,
gpa: std.mem.Allocator,

const default_block_size = 64 * 1024 * 1024; // 64MB

pub const PoolAllocatorOptions = struct {
    device: vk.DeviceProxy,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    block_size: vk.DeviceSize = default_block_size,
};
pub fn init(opts: *const PoolAllocatorOptions, gpa: std.mem.Allocator) !PoolAllocator {
    const pools = try gpa.alloc(Pool, opts.memory_properties.memory_type_count);
    for (pools, 0..) |*p, i| {
        const host_visible = opts.memory_properties.memory_types[i].property_flags.host_visible_bit;
        p.bda_arena = .init(opts.device, opts.block_size, @intCast(i), .{ .device_address_bit = true }, host_visible);
        p.linear_arena = .init(opts.device, opts.block_size, @intCast(i), .{}, host_visible);
        p.nonlinear_arena = .init(opts.device, opts.block_size, @intCast(i), .{}, host_visible);
    }
    return .{
        .device = opts.device,
        .memory_properties = opts.memory_properties,
        .pools = pools,
        .block_size = opts.block_size,
        .gpa = gpa,
    };
}

pub fn deinit(self: *const PoolAllocator) void {
    for (self.pools) |*p| {
        p.bda_arena.free(self.device, self.gpa);
        p.linear_arena.free(self.device, self.gpa);
        p.nonlinear_arena.free(self.device, self.gpa);
    }
    self.gpa.free(self.pools);
}

pub fn reset(self: *const PoolAllocator) void {
    for (self.pools) |*p| {
        p.bda_arena.reset();
        p.linear_arena.reset();
        p.nonlinear_arena.reset();
    }
}

pub const ObjectKind = enum(u8) {
    linear = 0,
    nonlinear = 1,
};
pub const AllocateOptions = struct {
    requirements: vk.MemoryRequirements,
    properties: vk.MemoryPropertyFlags,
    flags: vk.MemoryAllocateFlags = .{},
    kind: ObjectKind,
};
pub fn allocate(pa: *const PoolAllocator, opts: *const AllocateOptions, allocator: std.mem.Allocator) !Allocation {
    std.debug.assert(opts.requirements.size <= pa.block_size);
    const memory_index_type = try findMemoryTypeIndex(&pa.memory_properties, opts.requirements.memory_type_bits, opts.properties);
    // determine which arena to use
    const arena: *ChunkArena = if (opts.kind == .linear and opts.flags.device_address_bit)
        &pa.pools[memory_index_type].bda_arena
    else if (opts.kind == .linear)
        &pa.pools[memory_index_type].linear_arena
    else
        &pa.pools[memory_index_type].nonlinear_arena;
    // if stack is non-empty, we use the head. otherwise, create first chunk
    var head: *Chunk = if (arena.peek()) |head|
        head
    else
        try arena.push(allocator);

    // add padding to the current offset to ensure alignment
    var start_offset = computePadding(head.offset, opts.requirements.alignment);
    // NOW we check if we can add, after calculating the aligned offset
    if (start_offset + opts.requirements.size > head.size) {
        head = try arena.push(allocator);
        start_offset = 0;
    }
    head.offset = start_offset + opts.requirements.size;
    return Allocation{
        .handle = head.handle,
        .size = opts.requirements.size,
        .offset = start_offset,
        // convert base to u64 to perform ptr math, so the ptr correctly points to the mapping for this allocation
        .mapped = if (head.mapped) |base| @ptrFromInt(@intFromPtr(base) + start_offset) else null,
    };
}

fn findMemoryTypeIndex(memory_properties: *const vk.PhysicalDeviceMemoryProperties, memory_types: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (memory_properties.memory_types[0..memory_properties.memory_type_count], 0..) |mem_type, i| {
        if (memory_types & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

fn computePadding(offset: vk.DeviceSize, alignment: u64) vk.DeviceSize {
    std.debug.assert(alignment != 0 and (alignment & (alignment - 1)) == 0);
    return (offset + (alignment - 1)) & ~(alignment - 1);
}

pub const Allocation = struct {
    handle: vk.DeviceMemory,
    size: vk.DeviceSize,
    offset: vk.DeviceSize,
    mapped: ?*anyopaque,
};

const Chunk = struct {
    handle: vk.DeviceMemory,
    size: vk.DeviceSize,
    offset: vk.DeviceSize,
    mapped: ?*anyopaque,
    next: ?*Chunk,
};

const ChunkArena = struct {
    head: ?*Chunk = null,
    device: vk.DeviceProxy, // Specific to a device! Cannot use another!
    block_size: vk.DeviceSize,
    memory_index_type: u32,
    flags: vk.MemoryAllocateFlags,
    host_visible: bool,

    fn init(device: vk.DeviceProxy, block_size: vk.DeviceSize, memory_index_type: u32, flags: vk.MemoryAllocateFlags, host_visible: bool) ChunkArena {
        return .{
            .device = device,
            .block_size = block_size,
            .memory_index_type = memory_index_type,
            .flags = flags,
            .host_visible = host_visible,
        };
    }

    /// Allocates and pushes a Chunk onto the stack.
    fn push(
        ca: *ChunkArena,
        allocator: std.mem.Allocator,
    ) !*Chunk {
        // if there's been a reset we have chunks already good to go
        if (ca.head) |head| {
            if (head.next) |next| {
                std.debug.print("PoolAllocator.zig(push): re-used old chunk!\n", .{});
                ca.head = next;
                return ca.head.?;
            }
        }
        std.debug.print("PoolAllocator.zig(push): allocated new chunk!\n", .{});
        // otherwise, allocate new chunk
        const allocate_flags_info = vk.MemoryAllocateFlagsInfo{
            .flags = ca.flags,
            .device_mask = 0,
        };
        const c = try allocator.create(Chunk);
        errdefer allocator.destroy(c);
        const memory = try ca.device.allocateMemory(&.{
            .p_next = &allocate_flags_info,
            .allocation_size = ca.block_size,
            .memory_type_index = ca.memory_index_type,
        }, null);
        errdefer ca.device.freeMemory(memory, null);
        c.* = .{
            .size = ca.block_size,
            .offset = 0,
            .next = ca.head,
            .handle = memory,
            .mapped = if (ca.host_visible) try ca.device.mapMemory(memory, 0, ca.block_size, .{}) else null,
        };
        ca.head = c;
        return c;
    }

    /// Pops a Chunk off the stack and frees them. Asserts head is not null
    fn pop(ca: *ChunkArena, allocator: std.mem.Allocator) void {
        std.debug.assert(ca.head != null);
        const temp = ca.head.?;
        ca.head = ca.head.?.next;
        allocator.destroy(temp);
    }

    /// Frees all Chunks pushed onto the stack
    fn free(ca: *ChunkArena, device: vk.DeviceProxy, allocator: std.mem.Allocator) void {
        while (ca.head != null) {
            const c = ca.peek().?;
            if (c.mapped != null) device.unmapMemory(c.handle);
            device.freeMemory(c.handle, null);
            ca.pop(allocator);
        }
    }

    /// Resets the offsets for all chunks pushed onto the stack, then sets the bottom of the stack as the head
    fn reset(ca: *ChunkArena) void {
        var cur = ca.peek();
        while (cur != null) {
            cur.?.offset = 0;
            cur = cur.?.next;
        }
    }

    fn peek(ca: *ChunkArena) ?*Chunk {
        return ca.head;
    }
};

const Pool = struct {
    linear_arena: ChunkArena,
    nonlinear_arena: ChunkArena,
    bda_arena: ChunkArena,
};
