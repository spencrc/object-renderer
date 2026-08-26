// Input structure replacing GLSL Stage Inputs
struct FSInput
{
    float3 v_color : COLOR0;
};

// Fragment entry point returning the color output
[shader("fragment")]
float4 main(FSInput input) : SV_Target0
{
    return float4(input.v_color, 1.0);
}
