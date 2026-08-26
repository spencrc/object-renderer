struct FSInput
{
    float3 vColor;
};

[shader("fragment")]
float4 main(FSInput input) : SV_TARGET
{
    return float4(input.vColor, 1.0);
}
