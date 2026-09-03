const vk = @import("vulkan");

const Vertex = @This();

pub const binding_description = [_]vk.VertexInputBindingDescription{};

pub const attribute_description = [_]vk.VertexInputAttributeDescription{};

pos: [3]f32,
color: [3]f32,
