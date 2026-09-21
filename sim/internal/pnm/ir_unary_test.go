package pnm

import (
	"strings"
	"testing"
)

// TestCompileR_TrailingComment asserts R '#' comments (including inline ones)
// are stripped so a statement with a trailing comment still compiles.
func TestCompileR_TrailingComment(t *testing.T) {
	src := "x <- 2 + 3 # answer"
	prog, err := CompileR(src)
	if err != nil {
		t.Fatalf("trailing comment should compile: %v", err)
	}
	if !strings.Contains(prog.Emit(), "f64.add") {
		t.Fatalf("expected f64.add in IR, got:\n%s", prog.Emit())
	}
}

// TestCompileR_FullLineCommentsOnly asserts blank and full-line-comment inputs
// still produce an empty (no-op) program.
func TestCompileR_FullLineCommentsOnly(t *testing.T) {
	prog, err := CompileR("# just a comment")
	if err != nil {
		t.Fatalf("comment-only input should compile: %v", err)
	}
	if len(prog.Regs) != 0 {
		t.Fatalf("expected empty program, got %d instructions", len(prog.Regs))
	}
}

// TestSplitArith_DoubleStarRejected asserts R exponentiation ('**') is NOT
// silently treated as a binary multiply, which previously produced
// `a * (* b)` (a garbage variable) instead of an error.
func TestSplitArith_DoubleStarRejected(t *testing.T) {
	op, lhs, rhs, ok := splitArith("a ** b")
	if ok {
		t.Fatalf("a ** b should not split, got op=%q lhs=%q rhs=%q", op, lhs, rhs)
	}
	// And it should now surface as a clear unsupported-expression error in R
	// rather than a silently-wrong multiply.
	_, err := CompileR("x <- a ** b")
	if err == nil {
		t.Fatalf("a ** b should produce an error, not a silent miscompile")
	}
	if !strings.Contains(err.Error(), "unsupported R expression") {
		t.Fatalf("expected clear unsupported-expression error, got: %v", err)
	}
}

// TestSplitArith_PrecedenceAndParens asserts the splitter keeps operator
// precedence and parenthesis nesting intact for compound expressions.
func TestSplitArith_PrecedenceAndParens(t *testing.T) {
	cases := []struct {
		expr string
		op   byte
		lhs  string
		rhs  string
	}{
		{"a + b * c", '+', "a", "b * c"},
		{"a * b + c", '+', "a * b", "c"},
		{"(a + b) * (c - d)", '*', "(a + b)", "(c - d)"},
		{"a / -b", '/', "a", "-b"},
		{"a / b", '/', "a", "b"},
		{"a * -b", '*', "a", "-b"},
		{"a - -b", '-', "a", "-b"},
		{"a + -b", '+', "a", "-b"},
	}
	for _, c := range cases {
		op, lhs, rhs, ok := splitArith(c.expr)
		if !ok {
			t.Errorf("%q: expected a split", c.expr)
			continue
		}
		if op != c.op || lhs != c.lhs || rhs != c.rhs {
			t.Errorf("%q: got op=%q lhs=%q rhs=%q, want op=%q lhs=%q rhs=%q",
				c.expr, op, lhs, rhs, c.op, c.lhs, c.rhs)
		}
	}
}
