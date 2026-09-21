-- hello.hs — a simple Haskell program for the PNM chassis.
--
-- Computes f(x, y) = x * y + x + y using FP64 arithmetic.
-- Each operation (mul, add, add) maps to a node on the 2x2x2 chassis.
--
--   go run ./cmd/haskell_pnm examples/hello.hs -l 2 -x 2 -y 2
--   go run ./cmd/haskell_pnm examples/hello.hs -l 2 -x 2 -y 2 -run

mul x y = x * y
add a b = a + b

f x y = add (add (mul x y) x) y
