const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("sdl3");
const Instance = @import("instance.zig");
const Vertex = @import("vertex.zig");

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*; // bytecode pointer is u32, hence the align
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;
const depth_format = vk.Format.d32_sfloat;

const QueueFamilyIndices = struct {
    graphics_family_index: u32,
    present_family_index: u32,
};

const DeviceCandidate = struct {
    pdevice: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueFamilyIndices,
};

const GraphicsContext = @This();

allocator: std.mem.Allocator,
instance: *Instance,
// vulkan objects
surface: vk.SurfaceKHR,

pdevice: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
graphics_family_index: u32,
present_family_index: u32,
device: vk.DeviceProxy,
mem_props: vk.PhysicalDeviceMemoryProperties,

surface_format: vk.SurfaceFormatKHR,
actual_extent: vk.Extent2D,
swapchain: vk.SwapchainKHR,
swap_image_views: []vk.ImageView,
render_complete_semaphores: []vk.Semaphore,
depth_image: vk.Image,
depth_image_mem: vk.DeviceMemory,
depth_image_view: vk.ImageView,

render_pass: vk.RenderPass,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

framebuffers: []vk.Framebuffer,

command_pool: vk.CommandPool,

pub fn deinit(self: *GraphicsContext) void {
    self.device.destroyCommandPool(self.command_pool, null);
    // framebuffer
    for (self.framebuffers) |fb| self.device.destroyFramebuffer(fb, null);
    self.allocator.free(self.framebuffers);
    // pipeline
    self.device.destroyPipeline(self.pipeline, null);
    self.device.destroyPipelineLayout(self.pipeline_layout, null);
    // render pass
    self.device.destroyRenderPass(self.render_pass, null);
    // swapchain
    self.device.destroyImageView(self.depth_image_view, null);
    self.device.freeMemory(self.depth_image_mem, null);
    self.device.destroyImage(self.depth_image, null);
    for (self.render_complete_semaphores) |s| self.device.destroySemaphore(s, null);
    self.allocator.free(self.render_complete_semaphores);
    for (self.swap_image_views) |si| self.device.destroyImageView(si, null);
    self.allocator.free(self.swap_image_views);
    self.device.destroySwapchainKHR(self.swapchain, null);
    // device
    self.device.destroyDevice(null);
    self.instance.proxy.destroySurfaceKHR(self.surface, null);
    // need to destroy wrappers as well to prevent mem leaks
    self.allocator.destroy(self.device.wrapper);
}

pub fn init(
    allocator: std.mem.Allocator,
    instance: *Instance,
    surface: vk.SurfaceKHR,
    screen_width: usize,
    screen_height: usize,
) !GraphicsContext {
    var self: GraphicsContext = undefined;
    self.allocator = allocator;
    self.instance = instance;
    self.surface = surface;

    try self.initDevice();

    try self.initSwapchain(screen_width, screen_height);

    try self.initRenderPass();

    try self.initPipeline();

    try self.initFramebuffer();

    self.command_pool = try self.device.createCommandPool(&.{
        .queue_family_index = self.graphics_family_index,
    }, null);

    return self;
}

pub fn findMemoryTypeIndex(self: GraphicsContext, memory_types: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
        if (memory_types & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

pub fn allocate(self: GraphicsContext, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    return try self.device.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
    }, null);
}

//**********************************************
// DEVICE CREATIONS FNS
//**********************************************

fn initDevice(self: *GraphicsContext) !void {
    const candidate = try pickCandidateDevice(self.instance.proxy, self.surface, self.allocator);
    self.pdevice = candidate.pdevice;
    self.props = candidate.props;
    self.graphics_family_index = candidate.queues.graphics_family_index;
    self.present_family_index = candidate.queues.present_family_index;

    const priority = [_]f32{1};
    const required_device_extensions = comptime getRequiredDeviceExtensions();
    const device = try self.instance.proxy.createDevice(self.pdevice, &.{
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

    const vkd = try self.allocator.create(vk.DeviceWrapper);
    errdefer self.allocator.destroy(vkd);
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

//**********************************************
// SWAPCHAIN CREATIONS FNS
//**********************************************

fn initSwapchain(self: *GraphicsContext, screen_width: usize, screen_height: usize) !void {
    const caps = try self.instance.proxy.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdevice, self.surface);
    const actual_extent = findSwapExtent(caps, screen_width, screen_height);
    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const surface_format = try findSurfaceFormat(self.instance.proxy, self.pdevice, self.surface, self.allocator);
    const present_mode = try findPresentMode(self.instance.proxy, self.pdevice, self.surface, self.allocator);

    const image_count = if (caps.max_image_count > 0)
        @min(caps.min_image_count, caps.max_image_count)
    else
        caps.min_image_count;

    const queue_family_index = [_]u32{ self.graphics_family_index, self.present_family_index };
    const sharing_mode: vk.SharingMode = if (self.graphics_family_index != self.present_family_index)
        .concurrent
    else
        .exclusive;

    const swapchain = try self.device.createSwapchainKHR(&.{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
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

    const images = try self.device.getSwapchainImagesAllocKHR(swapchain, self.allocator);
    defer self.allocator.free(images);

    const image_views = try self.allocator.alloc(vk.ImageView, images.len);
    errdefer self.allocator.free(image_views);

    const render_complete_semaphores = try self.allocator.alloc(vk.Semaphore, images.len);
    errdefer self.allocator.free(render_complete_semaphores);

    var i: usize = 0;
    errdefer for (image_views[0..i]) |iv| self.device.destroyImageView(iv, null);

    for (images) |image| {
        image_views[i] = try self.device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        render_complete_semaphores[i] = try self.device.createSemaphore(&.{}, null);

        i += 1;
    }

    const depth_image = try self.device.createImage(&.{
        .image_type = .@"2d",
        .format = depth_format,
        .extent = .{ .width = actual_extent.width, .height = actual_extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .initial_layout = .undefined,
        .sharing_mode = .exclusive,
    }, null);
    errdefer self.device.destroyImage(depth_image, null);
    const image_mem_reqs = self.device.getImageMemoryRequirements(depth_image);
    const image_mem = try self.allocate(image_mem_reqs, .{ .device_local_bit = true });
    errdefer self.device.freeMemory(image_mem, null);
    try self.device.bindImageMemory(depth_image, image_mem, 0);

    const depth_image_view = try self.device.createImageView(&.{
        .image = depth_image,
        .view_type = .@"2d",
        .format = depth_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);

    self.surface_format = surface_format;
    self.actual_extent = actual_extent;
    self.swapchain = swapchain;
    self.swap_image_views = image_views;
    self.render_complete_semaphores = render_complete_semaphores;
    self.depth_image = depth_image;
    self.depth_image_mem = image_mem;
    self.depth_image_view = depth_image_view;
}

fn findSurfaceFormat(
    instance: vk.InstanceProxy,
    pdevice: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !vk.SurfaceFormatKHR {
    const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdevice, surface, allocator);
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

fn findPresentMode(
    instance: vk.InstanceProxy,
    pdevice: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !vk.PresentModeKHR {
    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdevice, surface, allocator);
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

//**********************************************
// RENDER PASS CREATIONS FNS
//**********************************************

/// Creates the render pass object, which stores info about framebuffer attachments to be used while rendering
fn initRenderPass(self: *GraphicsContext) !void {
    const color_attachment = vk.AttachmentDescription{
        .format = self.surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
        // determines what we do before and after rendering:
        .load_op = .clear,
        .store_op = .store,
        // determines what stencil buffer data to apply:
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
    };

    self.render_pass = try self.device.createRenderPass(&.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
}

//**********************************************
// PIPELINE CREATIONS FNS
//**********************************************

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
        .p_color_attachment_formats = &[_]vk.Format{self.surface_format.format},
        .depth_attachment_format = depth_format,
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
        .render_pass = self.render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try self.device.createGraphicsPipelines(.null_handle, &.{pipeline_info}, null, (&pipeline)[0..1]);

    self.pipeline_layout = pipeline_layout;
    self.pipeline = pipeline;
}

//**********************************************
// FRAMEBUFFER CREATIONS FNS
//**********************************************

fn initFramebuffer(self: *GraphicsContext) !void {
    const framebuffers = try self.allocator.alloc(vk.Framebuffer, self.swap_image_views.len);
    errdefer self.allocator.free(framebuffers);

    for (self.swap_image_views, 0..) |si, i| {
        framebuffers[i] = try self.device.createFramebuffer(&.{
            .render_pass = self.render_pass,
            .height = self.actual_extent.height,
            .width = self.actual_extent.width,
            .layers = 1,
            .p_attachments = @ptrCast(&si),
            .attachment_count = 1,
        }, null);
    }

    self.framebuffers = framebuffers;
}
