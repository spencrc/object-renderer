struct VertexOutput
{
    float4 position : SV_Position;
    float3 color    : SV_Target;
};

static const float3 positions[3] = {
    float3( 0.0, -0.5, 0.0), // Top
    float3(-0.5,  0.5, 0.0), // Bottom Left
    float3( 0.5,  0.5, 0.0)  // Bottom Right
};

static const float3 colors[3] = {
    float3(1.0, 0.0, 0.0), // Red
    float3(0.0, 1.0, 0.0), // Green
    float3(0.0, 0.0, 1.0)  // Blue
};

[shader("vertex")]
VertexOutput main(uint vertexIndex : SV_VertexID)
{
    VertexOutput output;
    output.position = float4(positions[vertexIndex], 1.0);
    output.color = colors[vertexIndex];
    return output;
}
