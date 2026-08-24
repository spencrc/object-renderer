const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");
const Instance = @import("instance.zig");
const Vertex = @import("vertex.zig");
const Swapchain = @import("swapchain.zig");

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*; // bytecode pointer is u32, hence the align
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;
const max_frames_in_flight = 2;

const QueueFamilyIndices = struct {
    graphics_family_index: u32,
    present_family_index: u32,
};

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

const GraphicsContext = @This();

gpa: std.mem.Allocator,
instance: *Instance,
surface: vk.SurfaceKHR,

pdevice: vk.PhysicalDevice,
graphics_family_index: u32,
present_family_index: u32,
device: vk.DeviceProxy,
mem_props: vk.PhysicalDeviceMemoryProperties,

swapchain: Swapchain,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

timeline_semaphore: vk.Semaphore,
frame_resources: [max_frames_in_flight]FrameResources,

pub fn init(
    allocator: std.mem.Allocator,
    instance: *Instance,
    surface: vk.SurfaceKHR,
    screen_width: usize,
    screen_height: usize,
) !GraphicsContext {
    var self: GraphicsContext = undefined;
    self.gpa = allocator;
    self.instance = instance;
    self.surface = surface;

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

    return self;
}

pub fn deinit(self: *GraphicsContext) void {
    self.device.deviceWaitIdle() catch @panic("failed to wait for device to idle!");

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

const REQUIRED_DEVICE_EXTS = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
fn getRequiredDeviceExtensions() []const [*:0]const u8 {
    return switch (builtin.mode) {
        else => return &REQUIRED_DEVICE_EXTS,
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
        .p_vertex_binding_descriptions = @ptrCast(&Vertex.binding_description),
        .vertex_binding_description_count = 1,
        .p_vertex_attribute_descriptions = @ptrCast(&Vertex.attribute_description),
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
        .p_attachments = @ptrCast(&color_blend_attachment),
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
