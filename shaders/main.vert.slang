struct Vertex {
    float2 position;
    float3 color;
};

struct PushConstants {
    Vertex* vertexBuffer;
    uint16_t* indexBuffer;
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
VSOutput main(uint drawID : SV_VertexID)
{
    uint16_t index = pcs.indexBuffer[drawID];

    Vertex v = pcs.vertexBuffer[index];

    VSOutput output;
    output.pos = mul(pcs.proj, mul(pcs.view, mul(pcs.model, float4(v.position, 0.0, 1.0))));
    output.color = v.color;
    return output;
}
