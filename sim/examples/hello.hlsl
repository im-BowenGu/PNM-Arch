// hello.hlsl — a simple HLSL compute shader for the PNM chassis.
//
// Computes f(x, y) = x * y + x + y using FP32 ALU operations.
// Each operation maps to a node on the 2x2x2 chassis.
//
//   go run ./cmd/hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2
//   go run ./cmd/hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2 -run

float result = x * y;
result = result + x;
result = result + y;
