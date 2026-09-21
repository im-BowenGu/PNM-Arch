package pnm

import (
	"fmt"
	"math"
	"math/rand"
	"testing"
)

// Numeric-reference tests for the R frontend (and, via the shared splitArith,
// the Haskell and HLSL frontends).  These are deliberately stronger than the
// "compiles without error / produced instructions" property tests: they compile
// an expression, run it through the EvalFP64 interpreter oracle, and compare
// the *numeric result* against an independent Go reference evaluator.  This
// turns silent precedence / unary-minus / assoc mis-parses (which still emit
// instructions, so len>0 checks pass) into hard failures.
//
// The motivating bugs this guards against:
//   - a / -b, a * -b, a - -b split as a/1 - b etc. (splitArith unary handling)
//   - a + b * c parsed as (a+b)*c (operator precedence)
//   - a - b - c parsed as a - (b - c) (left associativity)

func refEvalR(line string, vals map[string]float64) float64 {
	// Independent reference that mirrors standard maths precedence:
	// parentheses > unary - > * / > + -, left-assoc for + and -.
	// Supports identifiers, numbers, unary minus, and + - * / only.
	i := 0
	n := len(line)
	var parseExpr, parseTerm, parsePrimary func() float64

	skip := func() {
		for i < n && (line[i] == ' ' || line[i] == '\t') {
			i++
		}
	}
	parsePrimary = func() float64 {
		skip()
		if i < n && line[i] == '(' {
			i++ // consume '('
			v := parseExpr()
			skip()
			if i < n && line[i] == ')' {
				i++
			}
			return v
		}
		// unary minus
		if i < n && line[i] == '-' {
			i++
			return -parsePrimary()
		}
		// number or identifier
		start := i
		for i < n {
			c := line[i]
			if (c >= '0' && c <= '9') || c == '.' || (c >= 'a' && c <= 'z') {
				i++
			} else {
				break
			}
		}
		tok := line[start:i]
		if v, ok := vals[tok]; ok {
			return v
		}
		var f float64
		if sscanf(tok, &f) {
			return f
		}
		return math.NaN()
	}
	parseTerm = func() float64 {
		v := parsePrimary()
		for {
			skip()
			if i < n && line[i] == '*' {
				i++
				v = v * parsePrimary()
			} else if i < n && line[i] == '/' {
				i++
				v = v / parsePrimary()
			} else {
				return v
			}
		}
	}
	parseExpr = func() float64 {
		v := parseTerm()
		for {
			skip()
			if i < n && line[i] == '+' {
				i++
				v = v + parseTerm()
			} else if i < n && line[i] == '-' {
				i++
				v = v - parseTerm()
			} else {
				return v
			}
		}
	}
	return parseExpr()
}

func sscanf(tok string, out *float64) bool {
	neg := false
	s := 0
	if s < len(tok) && (tok[s] == '-' || tok[s] == '+') {
		neg = tok[s] == '-'
		s++
	}
	if s >= len(tok) {
		return false
	}
	ip := 0.0
	for s < len(tok) && tok[s] >= '0' && tok[s] <= '9' {
		ip = ip*10 + float64(tok[s]-'0')
		s++
	}
	f := ip
	if s < len(tok) && tok[s] == '.' {
		s++
		scale := 0.1
		for s < len(tok) && tok[s] >= '0' && tok[s] <= '9' {
			f += float64(tok[s]-'0') * scale
			scale /= 10
			s++
		}
	}
	if s != len(tok) {
		return false
	}
	if neg {
		f = -f
	}
	*out = f
	return true
}

func near(a, b float64) bool {
	if math.IsNaN(a) && math.IsNaN(b) {
		return true
	}
	d := math.Abs(a - b)
	scale := math.Max(1, math.Max(math.Abs(a), math.Abs(b)))
	return d <= 1e-6*scale
}

func TestRIR_NumericUnaryAndPrecedence(t *testing.T) {
	// Cases whose RHS unary minus is on a LITERAL are fully supported; the
	// compiled-and-interpreted result must match the reference exactly.
	cases := []struct {
		name string
		src  string // expression after "x <- "
		args []string
		vals []float64
	}{
		{"div_neg_lit", "a / -3", []string{"a"}, []float64{10}},
		{"mul_neg_lit", "a * -4", []string{"a"}, []float64{3}},
		{"sub_neg_lit", "a - -3", []string{"a"}, []float64{5}}, // = 8
		{"add_mul_prec", "a + b * c", []string{"a", "b", "c"}, []float64{1, 2, 3}},
		{"mul_add_prec", "a * b + c", []string{"a", "b", "c"}, []float64{2, 3, 4}},
		{"paren", "(a + b) * c", []string{"a", "b", "c"}, []float64{1, 2, 3}},
		{"left_assoc_sub", "a - b - c", []string{"a", "b", "c"}, []float64{10, 3, 2}},
		{"left_assoc_add", "a + b - c", []string{"a", "b", "c"}, []float64{1, 2, 3}},
		{"div_prec", "a + b / c", []string{"a", "b", "c"}, []float64{1, 10, 2}},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			src := "x <- " + c.src + "\n"
			got := runFP64Case(t, src, c.args, c.vals, "x")
			vals := map[string]float64{}
			for i, a := range c.args {
				vals[a] = c.vals[i]
			}
			want := refEvalR(c.src, vals)
			if !near(got, want) {
				t.Fatalf("%s: compiled %s gave %v, reference %v",
					c.name, c.src, got, want)
			}
		})
	}
}

// TestRIR_UnaryOnVariableNoSilentMiscompile guards the MEDIUM #29 class:
// `a / -b` (variable in a unary position after a binary operator) must NEVER
// silently compile to the wrong expression.  Variable unary minus is a known
// limitation (documented), so a clean compile error is acceptable — but the
// pre-fix behavior (split as `a/1 - b`, i.e. silently wrong arithmetic) is not.
// If it compiles, the numeric result must equal the reference.
func TestRIR_UnaryOnVariableNoSilentMiscompile(t *testing.T) {
	cases := []struct {
		name string
		src  string
		args []string
		vals []float64
	}{
		{"div_neg", "a / -b", []string{"a", "b"}, []float64{10, 2}},
		{"mul_neg", "a * -b", []string{"a", "b"}, []float64{3, 4}},
		{"sub_neg", "a - -b", []string{"a", "b"}, []float64{5, 3}},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			src := "x <- " + c.src + "\n"
			if _, err := CompileR(src); err != nil {
				return // clean error: acceptable for this known limitation
			}
			// Compiled successfully: the numeric result MUST be correct.
			got := runFP64Case(t, src, c.args, c.vals, "x")
			vals := map[string]float64{}
			for i, a := range c.args {
				vals[a] = c.vals[i]
			}
			want := refEvalR(c.src, vals)
			if !near(got, want) {
				t.Fatalf("%s: %s compiled to a WRONG value %v (reference %v): variable unary minus must not silently miscompile", c.name, c.src, got, want)
			}
		})
	}
}

// TestRIR_RandomPrecedenceProperty generates random three-term expressions with
// negative constants and cross-checks the compiled-and-interpreted result
// against the reference evaluator.  This is the randomized generalization of the
// unary/precedence table above: it would catch any future regressions in
// splitArith or operator precedence across many operand/operator shapes.
func TestRIR_RandomPrecedenceProperty(t *testing.T) {
	ops := []string{"+", "-", "*", "/"}
	// random operand pool includes negative numbers (the historical bug source)
	pool := []float64{-7, -3.5, -1, 0.5, 2, 3, 4, 10}
	rng := rand.New(rand.NewSource(20260828))

	for iter := 0; iter < 500; iter++ {
		o1 := ops[rng.Intn(len(ops))]
		o2 := ops[rng.Intn(len(ops))]
		a := pool[rng.Intn(len(pool))]
		b := pool[rng.Intn(len(pool))]
		c := pool[rng.Intn(len(pool))]
		// avoid divide-by-zero producing inf vs finite mismatch
		if o1 == "/" && b == 0 {
			b = 2
		}
		if o2 == "/" && c == 0 {
			c = 2
		}
		expr := fmt.Sprintf("%g %s %g %s %g", a, o1, b, o2, c)
		src := "x <- " + expr + "\n"

		if _, err := CompileR(src); err != nil {
			t.Fatalf("iter %d: CompileR(%q) errored: %v", iter, expr, err)
		}
		got := runFP64Case(t, src, nil, nil, "x") // constants only, no vars
		want := refEvalR(expr, nil)
		if !near(got, want) {
			t.Fatalf("iter %d: %s compiled %v, reference %v", iter, expr, got, want)
		}
	}
}
