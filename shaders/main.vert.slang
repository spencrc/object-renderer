struct Vertex {
    float3 position;
    float3 color;
};

struct PushConstants {
    Vertex* vertexBuffer;
    uint pad1;
    uint pad2;
    float4x4 model;
};
[[vk::push_constant]] PushConstants pcs;

struct UniformBuffer {
    float4x4 view;
    float4x4 proj;
};
ConstantBuffer<UniformBuffer> ubo;

struct VSOutput
{
    float4 pos : SV_Position;
    float3 color;
};

[shader("vertex")]
VSOutput main(uint16_t vertexID : SV_VertexID)
{
    Vertex v = pcs.vertexBuffer[vertexID];

    VSOutput output;
    output.pos = mul(ubo.proj, mul(ubo.view, mul(pcs.model, float4(v.position, 1.0))));
    output.color = v.color;
    return output;
}
