# hello.R — a simple R program for the PNM chassis.
#
# Computes f(x, y) = x * y + x + y using FP64 arithmetic.
# Each operation (mul, add, add) maps to a node on the 2x2x2 chassis.
#
#   go run ./cmd/r_pnm examples/hello.R -l 2 -x 2 -y 2
#   go run ./cmd/r_pnm examples/hello.R -l 2 -x 2 -y 2 -run

result <- x * y
result <- result + x
result <- result + y
