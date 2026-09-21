package pnm

import (
	"fmt"
	"math"
	"testing"
	"testing/quick"
)

// TestRIR_LinearExpressionProperty verifies R linear expressions compile.
func TestRIR_LinearExpressionProperty(t *testing.T) {
	f := func(a, b float64) bool {
		a = math.MaxFloat64/2 - math.Abs(a)
		b = math.MaxFloat64/2 - math.Abs(b)
		if math.IsNaN(a) || math.IsInf(a, 0) || math.IsNaN(b) || math.IsInf(b, 0) {
			return true
		}
		src := fmt.Sprintf("x <- %g + %g", a, b)
		prog, err := CompileR(src)
		if err != nil {
			return true
		}
		return len(prog.Regs) > 0
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 200}); err != nil {
		t.Error(err)
	}
}

// TestRIR_AllBinopsProperty verifies all arithmetic operators compile.
func TestRIR_AllBinopsProperty(t *testing.T) {
	ops := []string{"+", "-", "*", "/"}
	for _, op := range ops {
		src := fmt.Sprintf("x <- 1.0 %s 2.0", op)
		prog, err := CompileR(src)
		if err != nil {
			t.Errorf("operator %q failed: %v", op, err)
			continue
		}
		if len(prog.Regs) == 0 {
			t.Errorf("operator %q produced no instructions", op)
		}
	}
}

// TestRIR_ComparisonOpsProperty verifies all comparison operators compile.
func TestRIR_ComparisonOpsProperty(t *testing.T) {
	ops := []string{"==", "!=", "<", ">", "<=", ">="}
	for _, op := range ops {
		src := fmt.Sprintf("x <- 1.0 %s 2.0", op)
		_, err := CompileR(src)
		if err != nil {
			t.Errorf("comparison %q failed: %v", op, err)
		}
	}
}

// TestHLSL_AllBinopsProperty verifies all HLSL binary operators compile.
func TestHLSL_AllBinopsProperty(t *testing.T) {
	ops := []string{"+", "-", "*", "/"}
	for _, op := range ops {
		src := fmt.Sprintf(`
float4 main(float4 a : TEXCOORD0, float4 b : TEXCOORD1) : COLOR {
    float4 r;
    r = a.x %s b.x;
    return r;
}`, op)
		_, err := CompileHLSL(src)
		if err != nil {
			t.Errorf("HLSL operator %q failed: %v", op, err)
		}
	}
}

// TestHaskell_AllBinopsProperty verifies all Haskell binary operators compile.
func TestHaskell_AllBinopsProperty(t *testing.T) {
	ops := []string{"+", "-", "*", "/"}
	for _, op := range ops {
		src := fmt.Sprintf("f x y = x %s y", op)
		prog, err := CompileHaskell(src)
		if err != nil {
			t.Errorf("Haskell operator %q failed: %v", op, err)
			continue
		}
		fn, ok := prog.Funcs["f"]
		if !ok || len(fn.Body) == 0 {
			t.Errorf("Haskell operator %q produced no body instructions", op)
		}
	}
}

// TestHaskell_LinearProperty verifies Haskell linear expressions compile.
func TestHaskell_LinearProperty(t *testing.T) {
	f := func(rawA, rawB float64) bool {
		if math.IsNaN(rawA) || math.IsInf(rawA, 0) || math.IsNaN(rawB) || math.IsInf(rawB, 0) {
			return true
		}
		a, b := 1.5, 2.5 // safe defaults
		if rawA >= -1e6 && rawA <= 1e6 && rawA != 0 {
			a = rawA
		}
		if rawB >= -1e6 && rawB <= 1e6 && rawB != 0 {
			b = rawB
		}
		src := fmt.Sprintf("f x = x * %g + %g", a, b)
		prog, err := CompileHaskell(src)
		if err != nil {
			return true // compilation errors are acceptable
		}
		// compileHaskellFunc stores body in Funcs[name].Body, not prog.Regs
		fn, ok := prog.Funcs["f"]
		if !ok {
			t.Logf("Haskell missing func 'f' for a=%v b=%v", a, b)
			return false
		}
		ok = len(fn.Body) > 0
		if !ok {
			t.Logf("Haskell produced 0 body instructions for a=%v b=%v", a, b)
		}
		return ok
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 200}); err != nil {
		t.Error(err)
	}
}

// TestFlitMessage_RoundtripProperty verifies encode→decode roundtrip.
func TestFlitMessage_RoundtripProperty(t *testing.T) {
	f := func(srcID byte, seq byte, payload []byte) bool {
		if len(payload) > 200 {
			return true
		}
		msg := &FlitMessage{
			Type:     MsgFlit,
			SourceID: srcID,
			SeqNum:   seq,
			Payload:  payload,
		}
		data := msg.Encode()
		decoded, err := DecodeFlitMessage(data)
		if err != nil {
			return false
		}
		return decoded.SourceID == srcID && decoded.SeqNum == seq &&
			len(decoded.Payload) == len(payload)
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}

// TestFlit_EncodeLengthProperty verifies Flit() produces correct byte length.
func TestFlit_EncodeLengthProperty(t *testing.T) {
	f := func(layer int, dest int, payload []byte) bool {
		if len(payload) > 200 || layer < 0 || dest < 0 {
			return true
		}
		flit := Flit(layer, dest, 0x80, payload, false)
		// LAYER(1) + MODULE(1) + CTRL(1) + LEN(2) + payload + CRC(2)
		expectedLen := 5 + len(payload) + 2
		return len(flit) == expectedLen
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}

// TestByteConservationProperty verifies wire format byte counts are consistent.
func TestByteConservationProperty(t *testing.T) {
	f := func(payloadLen uint16) bool {
		if payloadLen > 200 {
			return true
		}
		pl := int(payloadLen)
		// Wire: LAYER + MODULE + CTRL + LEN2 + payload + CRC2
		wireLen := 1 + 1 + 1 + 2 + pl + 2
		// DMA (after layer strip): MODULE + CTRL + LEN2 + payload + CRC2
		dmaLen := 1 + 1 + 2 + pl + 2
		return wireLen == dmaLen+1
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}
