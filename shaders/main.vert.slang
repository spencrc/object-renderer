struct Vertex {
    float2 position;
    float3 color;
};

struct PushConstants {
    Vertex* vertexBuffer;
    float4x4 model;
    float4x4 view;
    float4x4 proj;
};

[[vk::push_constant]] PushConstants pcs;

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
    output.pos = mul(pcs.proj, mul(pcs.view, mul(pcs.model, float4(v.position, 0.0, 1.0))));
    output.color = v.color;
    return output;
}
