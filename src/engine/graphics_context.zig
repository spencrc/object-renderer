const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");
const Instance = @import("instance.zig");
const Vertex = @import("vertex.zig");
const Swapchain = @import("swapchain.zig");

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*; // bytecode pointer is u32, hence the align
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;
const max_frames_in_flight = 2;
const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

// TODO: create Queue struct that stores both index and VkQueue object
const QueueFamilyIndices = struct {
    graphics_family_index: u32,
    present_family_index: u32,
};

// TODO: make physical device initialization its own file/struct since it's independent anyways
const DeviceCandidate = struct {
    pdevice: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueFamilyIndices,
};

const RequiredFeatures = struct {
    feats14: vk.PhysicalDeviceVulkan14Features = .{},
    feats13: vk.PhysicalDeviceVulkan13Features = .{
        .synchronization_2 = .true,
        .dynamic_rendering = .true,
    },
    feats12: vk.PhysicalDeviceVulkan12Features = .{
        .timeline_semaphore = .true,
    },

    fn chain(rf: *RequiredFeatures) vk.PhysicalDeviceFeatures2 {
        rf.feats12.p_next = &rf.feats13;
        rf.feats13.p_next = &rf.feats14;
        return .{ .p_next = &rf.feats12, .features = .{} };
    }

    fn isSupported(rf: *const RequiredFeatures) bool {
        return rf.feats13.synchronization_2 == .true and
            rf.feats13.dynamic_rendering == .true and
            rf.feats12.timeline_semaphore == .true;
    }
};

const FrameResources = struct {
    command_pool: vk.CommandPool, // per frame resource command pool = faster command buffer reset
    command_buffer: vk.CommandBuffer,
    image_acquired_semaphore: vk.Semaphore, // used to block rendering until able to present (go-ahead from GPU)
};

const Buffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
};

const GraphicsContext = @This();

gpa: std.mem.Allocator,
instance: *const Instance,
surface: vk.SurfaceKHR,

// TODO: move away from default values for fields. will need to re-write a lot of the funcs.
pdevice: vk.PhysicalDevice = .null_handle,
graphics_family_index: u32 = std.math.maxInt(u32),
present_family_index: u32 = std.math.maxInt(u32),
mem_props: vk.PhysicalDeviceMemoryProperties = undefined,
device: vk.DeviceProxy = undefined,
graphics_queue: vk.Queue = .null_handle,
present_queue: vk.Queue = .null_handle, // in theory, provides minor performance boost

swapchain: Swapchain = undefined,

pipeline_layout: vk.PipelineLayout = .null_handle,
pipeline: vk.Pipeline = .null_handle,

timeline_semaphore: vk.Semaphore = .null_handle,
frame_resources: [max_frames_in_flight]FrameResources = undefined,

vertex_buffer: Buffer = undefined,

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
    var self = GraphicsContext{
        .gpa = gpa,
        .instance = instance,
        .surface = surface,
    };

    try self.initDevice();
    errdefer self.deinitDevice();

    self.swapchain = try .init(&self, screen_width, screen_height, self.gpa);
    errdefer self.swapchain.deinit(&self);

    try self.initPipeline();
    errdefer self.deinitPipeline();

    const semaphore_type_info = vk.SemaphoreTypeCreateInfo{
        .semaphore_type = .timeline,
        .initial_value = max_frames_in_flight,
    };
    self.timeline_semaphore = try self.device.createSemaphore(&.{
        .p_next = &semaphore_type_info,
    }, null);
    errdefer self.device.destroySemaphore(self.timeline_semaphore, null);

    try self.initFrameResources();
    errdefer self.deinitFrameResources();

    const vertices_size = @sizeOf(@TypeOf(vertices));
    self.vertex_buffer = try self.initBuffer(
        vertices_size,
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .{ .device_local_bit = true },
    );
    errdefer self.deinitBuffer(self.vertex_buffer);
    const command_pool = try self.device.createCommandPool(&.{
        .queue_family_index = self.graphics_family_index, // TODO: use transfer family
    }, null);
    defer self.device.destroyCommandPool(command_pool, null);
    try self.uploadVertices(command_pool, vertices_size);

    return self;
}

pub fn deinit(self: *GraphicsContext) void {
    self.device.deviceWaitIdle() catch @panic("failed to wait for device to idle!");

    self.deinitBuffer(self.vertex_buffer);

    self.deinitFrameResources();

    self.device.destroySemaphore(self.timeline_semaphore, null);

    self.deinitPipeline();

    self.swapchain.deinit(self);

    self.deinitDevice();
}

pub fn findMemoryTypeIndex(self: *const GraphicsContext, memory_types: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
        if (memory_types & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

pub fn allocate(self: *const GraphicsContext, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    return try self.device.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
    }, null);
}

/// Initializes device from supported physical device for Graphics Context
fn initDevice(self: *GraphicsContext) !void {
    const candidate = try pickCandidateDevice(self.instance.proxy, self.surface, self.gpa);
    self.pdevice = candidate.pdevice;
    // TODO: get transfer family index
    self.graphics_family_index = candidate.queues.graphics_family_index;
    self.present_family_index = candidate.queues.present_family_index;

    const priority = [_]f32{1};
    var required_features = RequiredFeatures{};
    const feats2 = required_features.chain();
    const required_device_extensions = comptime getRequiredDeviceExtensions();
    const device = try self.instance.proxy.createDevice(self.pdevice, &.{
        .p_next = &feats2,
        .queue_create_info_count = if (candidate.queues.graphics_family_index == candidate.queues.present_family_index) 1 else 2,
        .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = candidate.queues.graphics_family_index,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .queue_family_index = candidate.queues.present_family_index,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        },
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = required_device_extensions.ptr,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
    }, null);
    errdefer self.device.destroyDevice(null);

    const vkd = try self.gpa.create(vk.DeviceWrapper);
    errdefer self.gpa.destroy(vkd);
    vkd.* = vk.DeviceWrapper.load(device, self.instance.proxy.wrapper.dispatch.vkGetDeviceProcAddr.?);
    self.device = vk.DeviceProxy.init(device, vkd);
    self.mem_props = self.instance.proxy.getPhysicalDeviceMemoryProperties(self.pdevice);

    self.graphics_queue = self.device.getDeviceQueue(self.graphics_family_index, 0);
    self.present_queue = self.device.getDeviceQueue(self.present_family_index, 0);
}

fn pickCandidateDevice(
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !DeviceCandidate {
    const pdevices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevices);

    for (pdevices) |pdevice| {
        if (try getDeviceCandidate(pdevice, instance, surface, allocator)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevices;
}

fn getDeviceCandidate(
    pdevice: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !?DeviceCandidate {
    if (!try checkDeviceExtensionSupport(pdevice, instance, allocator)) return null;

    if (!try checkDeviceSurfaceSupport(pdevice, instance, surface)) return null;

    if (!checkDeviceFeaturesSupport(pdevice, instance)) return null;

    if (try findQueueFamilies(pdevice, instance, surface, allocator)) |queue_families| {
        const props = instance.getPhysicalDeviceProperties(pdevice);
        return DeviceCandidate{
            .pdevice = pdevice,
            .props = props,
            .queues = queue_families,
        };
    }

    return null;
}

fn checkDeviceExtensionSupport(
    pdevice: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    allocator: std.mem.Allocator,
) !bool {
    const properties_list = try instance.enumerateDeviceExtensionPropertiesAlloc(pdevice, null, allocator);
    defer allocator.free(properties_list);

    const required_device_extensions = comptime getRequiredDeviceExtensions();

    for (required_device_extensions) |required_extension| {
        for (properties_list) |props| {
            if (std.mem.eql(u8, std.mem.span(required_extension), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

const required_device_exts = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
fn getRequiredDeviceExtensions() []const [*:0]const u8 {
    return switch (builtin.mode) {
        else => return &required_device_exts,
    };
}

fn checkDeviceSurfaceSupport(
    pdevice: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,
) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdevice, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdevice, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkDeviceFeaturesSupport(pdevice: vk.PhysicalDevice, instance: vk.InstanceProxy) bool {
    var req = RequiredFeatures{};
    var feats = req.chain();
    instance.getPhysicalDeviceFeatures2(pdevice, &feats);
    return req.isSupported();
}

fn findQueueFamilies(
    pdevice: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !?QueueFamilyIndices {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdevice, allocator);
    defer allocator.free(families);

    var graphics_family_index: ?u32 = null;
    var present_family_index: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family_index == null and properties.queue_flags.graphics_bit) {
            graphics_family_index = family;
        }

        if (present_family_index == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdevice, family, surface)) == .true) {
            present_family_index = family;
        }
    }

    if (graphics_family_index != null and present_family_index != null) {
        return QueueFamilyIndices{
            .graphics_family_index = graphics_family_index.?,
            .present_family_index = present_family_index.?,
        };
    }

    return null;
}

fn deinitDevice(self: *GraphicsContext) void {
    // device
    self.device.destroyDevice(null);
    self.instance.proxy.destroySurfaceKHR(self.surface, null);
    // need to destroy wrappers as well to prevent mem leaks
    self.gpa.destroy(self.device.wrapper);
}

/// Initializes graphics pipeline for GraphicsContext
fn initPipeline(self: *GraphicsContext) !void {
    const pipeline_layout = try self.device.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    errdefer self.device.destroyPipelineLayout(pipeline_layout, null);

    const vert = try self.device.createShaderModule(&.{
        .code_size = vert_spv.len,
        .p_code = @ptrCast(&vert_spv),
    }, null);
    defer self.device.destroyShaderModule(vert, null);

    const frag = try self.device.createShaderModule(&.{
        .code_size = frag_spv.len,
        .p_code = @ptrCast(&frag_spv),
    }, null);
    defer self.device.destroyShaderModule(frag, null);

    const shader_stages_info = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
        },
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .p_vertex_binding_descriptions = &Vertex.binding_description,
        .vertex_binding_description_count = Vertex.binding_description.len,
        .p_vertex_attribute_descriptions = &Vertex.attribute_description,
        .vertex_attribute_description_count = Vertex.attribute_description.len,
    };

    const input_assembly_info = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const depth_stencil_info = vk.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = .true,
        .depth_write_enable = .true,
        .depth_compare_op = .less,
        .stencil_test_enable = .false,
        .depth_bounds_test_enable = .false,
        .min_depth_bounds = 0,
        .max_depth_bounds = 0,
        .front = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .reference = 0,
            .write_mask = 0,
        },
        .back = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .reference = 0,
            .write_mask = 0,
        },
    };

    const viewport_info = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = undefined, // set when creating command buffers
        .scissor_count = 1,
        .p_scissors = undefined, // set when creating command buffers
    };

    const rasterizer_info = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .line_width = 1.0,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
    };

    const multisampling_info = vk.PipelineMultisampleStateCreateInfo{
        .sample_shading_enable = .false,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1.0,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const color_blending_info = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{color_blend_attachment},
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    // enables changing the below at draw time, without recreating the pipeline
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_states_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    // enable dynamic rendering
    const render_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 1,
        .p_color_attachment_formats = &[_]vk.Format{self.swapchain.surface_format.format},
        .depth_attachment_format = Swapchain.depth_format,
        .stencil_attachment_format = .undefined,
        .view_mask = 0,
    };

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_next = &render_info,
        .p_stages = &shader_stages_info,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly_info,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport_info,
        .p_rasterization_state = &rasterizer_info,
        .p_multisample_state = &multisampling_info,
        .p_depth_stencil_state = &depth_stencil_info,
        .p_color_blend_state = &color_blending_info,
        .p_dynamic_state = &dynamic_states_info,
        .layout = pipeline_layout,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try self.device.createGraphicsPipelines(.null_handle, &.{pipeline_info}, null, (&pipeline)[0..1]);

    self.pipeline_layout = pipeline_layout;
    self.pipeline = pipeline;
}

fn deinitPipeline(self: *GraphicsContext) void {
    self.device.destroyPipeline(self.pipeline, null);
    self.device.destroyPipelineLayout(self.pipeline_layout, null);
}

/// Initializes array of frame resources for GraphicsContext
fn initFrameResources(self: *GraphicsContext) !void {
    var frame_resources: [max_frames_in_flight]FrameResources = undefined;
    for (&frame_resources) |*res| {
        const image_acquired_semaphore = try self.device.createSemaphore(&.{}, null);
        errdefer self.device.destroySemaphore(image_acquired_semaphore, null);

        const command_pool = try self.device.createCommandPool(&.{
            .queue_family_index = self.graphics_family_index,
        }, null);
        errdefer self.device.destroyCommandPool(command_pool, null);

        var command_buffer: vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&.{
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
    self.frame_resources = frame_resources;
}

fn deinitFrameResources(self: *GraphicsContext) void {
    for (self.frame_resources) |res| {
        self.device.freeCommandBuffers(res.command_pool, &.{res.command_buffer});
        self.device.destroyCommandPool(res.command_pool, null);
        self.device.destroySemaphore(res.image_acquired_semaphore, null);
    }
}

/// Helper method that returns a struct containing the VkBuffer and VkDeviceMemory objects for a buffer
fn initBuffer(self: *GraphicsContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags) !Buffer {
    const buffer = try self.device.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer self.device.destroyBuffer(buffer, null);
    const mem_reqs = self.device.getBufferMemoryRequirements(buffer);
    const mem = try self.allocate(mem_reqs, properties);
    errdefer self.device.freeMemory(mem, null);
    try self.device.bindBufferMemory(buffer, mem, 0);
    return .{
        .handle = buffer,
        .memory = mem,
    };
}

fn deinitBuffer(self: *GraphicsContext, buffer: Buffer) void {
    self.device.freeMemory(buffer.memory, null);
    self.device.destroyBuffer(buffer.handle, null);
}

/// Takes vertices from file-scope and outputs a Buffer (VkBuffer + VkDeviceMemory) object
// TODO: take vertices as param instead
fn uploadVertices(self: *GraphicsContext, command_pool: vk.CommandPool, size: vk.DeviceSize) !void {
    const staging_buffer = try self.initBuffer(
        size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    errdefer self.deinitBuffer(staging_buffer);

    {
        const data = try self.device.mapMemory(staging_buffer.memory, 0, vk.WHOLE_SIZE, .{});
        defer self.device.unmapMemory(staging_buffer.memory);

        const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(gpu_vertices, vertices[0..]);
    }

    try self.copyBuffer(command_pool, staging_buffer, self.vertex_buffer, size);
}

fn copyBuffer(self: *GraphicsContext, command_pool: vk.CommandPool, src: Buffer, dst: Buffer, size: vk.DeviceSize) !void {
    var command_buffer: vk.CommandBuffer = undefined;
    try self.device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer));
    defer self.device.freeCommandBuffers(command_pool, &.{command_buffer});

    try self.device.beginCommandBuffer(command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const copy_region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    self.device.cmdCopyBuffer(command_buffer, src.handle, dst.handle, &.{copy_region});

    try self.device.endCommandBuffer(command_buffer);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = &.{command_buffer},
        .p_wait_dst_stage_mask = undefined,
    };
    // TODO: use transfer queue or pass queue as param
    try self.device.queueSubmit(self.graphics_queue, &.{submit_info}, .null_handle);
    try self.device.queueWaitIdle(self.graphics_queue);
}

/// To be called inside application loop to actually draw!
pub fn render(self: *GraphicsContext, screen_width: usize, screen_height: usize) !void {
    if (self.recreate_swapchain) {
        try self.swapchain.recreate(self, screen_width, screen_height);
        self.recreate_swapchain = false;
    }

    const frame_resource_index: u32 = self.next_frame_index;
    self.next_frame_index = (self.next_frame_index + 1) % max_frames_in_flight;

    const signal_value: u64 = self.next_signal_value;
    self.next_signal_value += 1;

    const wait_value: u64 = signal_value - max_frames_in_flight;

    _ = try self.device.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = &[_]vk.Semaphore{self.timeline_semaphore},
        .p_values = &[_]u64{wait_value},
    }, std.math.maxInt(u64));
    // Q: for the first two frames, what happens? don't they have nothing to wait on?
    // A: actually, they do! the signal will be for the third frame for the first frame.
    // then, the third frame will re-use the first frame's resources as its wait value will be 3.

    const res = self.frame_resources[frame_resource_index];
    try self.device.resetCommandPool(res.command_pool, .{});

    const swapchain_width = self.swapchain.extent.width;
    const swapchain_height = self.swapchain.extent.height;

    const acquire_result = self.device.acquireNextImageKHR(self.swapchain.handle, std.math.maxInt(u64), res.image_acquired_semaphore, .null_handle) catch |err| switch (err) {
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
    try self.device.beginCommandBuffer(res.command_buffer, &.{
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
    self.device.cmdPipelineBarrier2(res.command_buffer, &.{
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
    self.device.cmdBeginRendering(res.command_buffer, &rendering_info);
    {
        const viewport = vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(swapchain_width),
            .height = @floatFromInt(swapchain_height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };
        self.device.cmdSetViewport(res.command_buffer, 0, &[_]vk.Viewport{viewport});

        // scissor test allows discarding areas outside of display region
        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = swapchain_width, .height = swapchain_height },
        };
        self.device.cmdSetScissor(res.command_buffer, 0, &[_]vk.Rect2D{scissor});

        self.device.cmdBindPipeline(res.command_buffer, .graphics, self.pipeline);
        self.device.cmdBindVertexBuffers(res.command_buffer, 0, &[_]vk.Buffer{self.vertex_buffer.handle}, &[_]u64{0});
        self.device.cmdDraw(res.command_buffer, 3, 1, 0, 0);
    }
    self.device.cmdEndRendering(res.command_buffer);

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
    self.device.cmdPipelineBarrier2(res.command_buffer, &.{
        .image_memory_barrier_count = present_layout_barriers.len,
        .p_image_memory_barriers = &present_layout_barriers,
    });

    try self.device.endCommandBuffer(res.command_buffer);

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
    try self.device.queueSubmit2(self.graphics_queue, &[_]vk.SubmitInfo2{submit_info}, .null_handle);

    // present the image
    const present_result = self.device.queuePresentKHR(self.present_queue, &vk.PresentInfoKHR{
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
