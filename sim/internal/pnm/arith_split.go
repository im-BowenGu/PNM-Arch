package pnm

import "strings"

// binaryOp precedence levels (higher binds tighter).  The integer value is
// used only for comparisons.
const (
	opPrecAdd = 1 // + -
	opPrecMul = 2 // * /
)

// splitArith splits an arithmetic expression at its top-level binary operator,
// respecting parentheses nesting and operator precedence.  For operators of the
// same precedence the rightmost one is chosen, which yields left-associative
// grouping ((a - b) - c, not a - (b - c)).  It returns the operator character,
// the left and right sub-expressions, and whether a split was found.
//
// Parentheses at nesting depth > 0 never split the expression, so "(b + c)"
// inside "a * (b + c)" is treated as a single operand.
func splitArith(expr string) (opCh byte, lhs, rhs string, ok bool) {
	bestIdx := -1
	bestPrec := 0
	depth := 0
	for i := 0; i < len(expr); i++ {
		c := expr[i]
		switch c {
		case '(':
			depth++
		case ')':
			if depth > 0 {
				depth--
			}
		case '+', '-', '*', '/':
			// A '*' followed by another '*' is R-style exponentiation ('**'),
			// which no frontend here supports; never treat it as a multiply
			// split (it would silently miscompile as `a * (* b)`).  Leave it
			// to fall through to a clear per-language "unsupported" error.
			if c == '*' && i+1 < len(expr) && expr[i+1] == '*' {
				continue
			}
			// Only a binary operator at depth 0 whose left side is a complete
			// operand can split the expression.  A plus/minus immediately
			// following another operator is a unary sign (e.g. "a * -b",
			// "a - -b"), not a binary operator; treating it as one would
			// mis-split into lhs="a *", rhs="b".
			if depth != 0 || !prevIsOperand(expr, i) {
				continue
			}
			prec := opPrecAdd
			if c == '*' || c == '/' {
				prec = opPrecMul
			}
			// Same precedence -> take the rightmost (left-assoc).  Lower
			// precedence overrides a higher one regardless of position.
			if bestIdx == -1 || prec < bestPrec || (prec == bestPrec && i > bestIdx) {
				bestIdx = i
				bestPrec = prec
			}
		}
	}
	if bestIdx == -1 {
		return 0, "", "", false
	}
	opCh = expr[bestIdx]
	lhs = strings.TrimSpace(expr[:bestIdx])
	rhs = strings.TrimSpace(expr[bestIdx+1:])
	return opCh, lhs, rhs, true
}

// prevIsOperand reports whether the character at or before expr[i] (ignoring
// whitespace) ends an operand, i.e. a binary operator at i has a complete left
// operand.  Operators, '(' and the start of the string do NOT end an operand.
func prevIsOperand(expr string, i int) bool {
	for j := i - 1; j >= 0; j-- {
		switch expr[j] {
		case ' ', '\t':
			continue
		case '+', '-', '*', '/', '(':
			return false
		default:
			return true
		}
	}
	return false
}
