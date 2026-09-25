const std = @import("std");
const vk = @import("vulkan");
const math = @import("../math.zig");
const Device = @import("Device.zig");
const Vertex = @import("Vertex.zig");
const Swapchain = @import("Swapchain.zig");

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*; // bytecode pointer is u32, hence the align
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

pub const PushConstants = struct {
    vertex_buffer_address: vk.DeviceAddress,
    _padding: u64 = 0,
    model: math.Mat4,
};

const GraphicsPipeline = @This();

pipeline_layout: vk.PipelineLayout,
handle: vk.Pipeline,

pub fn init(device: *const Device, format: vk.Format, descriptor_set_layout: vk.DescriptorSetLayout) !GraphicsPipeline {
    const push_constant_ranges = [_]vk.PushConstantRange{
        .{
            .offset = 0,
            .stage_flags = .{ .vertex_bit = true },
            .size = @sizeOf(PushConstants),
        },
    };

    const pipeline_layout = try device.proxy.createPipelineLayout(&.{
        .push_constant_range_count = push_constant_ranges.len,
        .p_push_constant_ranges = &push_constant_ranges,
        .set_layout_count = 1,
        .p_set_layouts = &[_]vk.DescriptorSetLayout{descriptor_set_layout},
    }, null);
    errdefer device.proxy.destroyPipelineLayout(pipeline_layout, null);

    const vert = try device.proxy.createShaderModule(&.{
        .code_size = vert_spv.len,
        .p_code = @ptrCast(&vert_spv),
    }, null);
    defer device.proxy.destroyShaderModule(vert, null);

    const frag = try device.proxy.createShaderModule(&.{
        .code_size = frag_spv.len,
        .p_code = @ptrCast(&frag_spv),
    }, null);
    defer device.proxy.destroyShaderModule(frag, null);

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
        .p_color_attachment_formats = &[_]vk.Format{format},
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
    _ = try device.proxy.createGraphicsPipelines(.null_handle, &.{pipeline_info}, null, (&pipeline)[0..1]);

    return .{
        .handle = pipeline,
        .pipeline_layout = pipeline_layout,
    };
}

pub fn deinit(self: GraphicsPipeline, device: *const Device) void {
    device.proxy.destroyPipeline(self.handle, null);
    device.proxy.destroyPipelineLayout(self.pipeline_layout, null);
}
