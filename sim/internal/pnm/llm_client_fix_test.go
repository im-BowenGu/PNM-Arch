package pnm

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// TestSampleFromLogits_SamplingNotDegenerate verifies that temperature-based
// sampling is actually proportional (does NOT always pick the last/lowest-prob
// token, which was the pre-fix 2^32-divisor bug).
func TestSampleFromLogits_SamplingNotDegenerate(t *testing.T) {
	// Distribution strongly favoring token 0 over token 4.
	logits := []float32{5.0, 4.5, 4.0, 3.5, 3.0}
	const N = 500
	lastCount := 0
	for i := 0; i < N; i++ {
		tok := sampleFromLogits(logits, 0.7, 0.9, 0, 0, nil, 0, nil)
		if tok == len(logits)-1 {
			lastCount++
		}
	}
	// The lowest-prob token should NOT be the modal choice (it was 100% before).
	// With proper normalization it should appear only occasionally.
	if float64(lastCount) > float64(N)*0.5 {
		t.Fatalf("sampler degenerated: lowest-prob token chosen %d/%d times", lastCount, N)
	}
}

// TestSampleFromLogits_EmptyFilterFallsBack checks that a filter that empties
// the distribution (minP > 1) falls back to greedy instead of panicking.
func TestSampleFromLogits_EmptyFilterFallsBack(t *testing.T) {
	logits := []float32{0.1, 0.9, 0.5}
	// minP=2 makes cutoff > max probability, emptying the filtered set.
	got := sampleFromLogits(logits, 0.7, 0.9, 0, 2.0, nil, 0, nil)
	if got != 1 { // argmax over original logits is index 1
		t.Errorf("expected greedy fallback to index 1, got %d", got)
	}
}

// TestSampleFromLogits_NaNLogitsNoPanic ensures non-finite logits don't crash.
func TestSampleFromLogits_NaNLogitsNoPanic(t *testing.T) {
	logits := []float32{float32(math.NaN()), float32(math.Inf(1)), 0.5}
	// Should not panic regardless of filter settings.
	_ = sampleFromLogits(logits, 0.7, 0.9, 0, 0, nil, 0, nil)
	_ = sampleFromLogits(logits, 0.7, 0.9, 0, 0.5, nil, 0, nil)
}

// TestSampleFromLogits_NegativeTempGreedy ensures temperature<=0 is greedy.
func TestSampleFromLogits_NegativeTempGreedy(t *testing.T) {
	logits := []float32{0.1, 0.9, 0.5}
	got := sampleFromLogits(logits, -1.0, 0.9, 0, 0, nil, 0, nil)
	if got != 1 {
		t.Errorf("expected greedy argmax index 1, got %d", got)
	}
}

// TestGenerateWithBatching_ResultsRetained verifies that continuous batching
// returns every request's generated sequence. Before the fix, RemoveFinished
// dropped finished requests from the batch before result collection, so the
// final traversal ran over an empty batch and every results entry stayed nil.
func TestGenerateWithBatching_ResultsRetained(t *testing.T) {
	modelDir := filepath.Join(SimDir(), "examples", "gemma4_test_synthetic")
	if _, err := os.Stat(filepath.Join(modelDir, "config.json")); err != nil {
		t.Skip("gemma4_test_synthetic model not found")
	}
	dims := Dims{Layers: 4, Bx: 4, By: 4}
	client, err := NewLLMClient(LLMConfig{
		ModelDir:       modelDir,
		Dims:           dims,
		MaxTokens:      6,
		DataType:       CUTypeBF16FMA,
		EnableBatching: true,
	})
	if err != nil {
		t.Fatalf("NewLLMClient: %v", err)
	}
	// The (0 = disabled) semantics must survive construction: the constructor
	// used to silently rewrite TopP=0 to 0.9, making nucleus sampling
	// un-disableable.
	if client.Config.TopP != 0 {
		t.Errorf("TopP=0 (disabled) rewritten to %v by constructor", client.Config.TopP)
	}

	results, err := client.GenerateWithBatching([]string{"alpha prompt", "beta prompt beta"})
	if err != nil {
		t.Fatalf("GenerateWithBatching: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected 2 result entries, got %d", len(results))
	}
	for i, r := range results {
		if len(r) == 0 {
			t.Errorf("result %d empty: batching lost the generated sequence", i)
		}
	}
}

// TestStructuredFSM_LiteralSingleCharNotWidened verifies that a literal
// character class such as [a] only accepts the exact character. Before the
// fix, the shorthand range checks in canAdvance/Advance treated any lowercase
// letter as matching a literal 'a' transition (and likewise 'A'/'0').
func TestStructuredFSM_LiteralSingleCharNotWidened(t *testing.T) {
	fsm, err := CompileStructuredFSM("[a]")
	if err != nil {
		t.Fatalf("CompileStructuredFSM: %v", err)
	}
	if fsm.canAdvance('a') != true {
		t.Error("canAdvance('a') should be true for [a]")
	}
	if fsm.canAdvance('b') {
		t.Error("canAdvance('b') must be false for [a]: literal widened to whole alphabet")
	}
	if fsm.canAdvance('A') {
		t.Error("canAdvance('A') must be false for [a]")
	}

	// Advance through an actual 'a' succeeds and completes the one-char
	// pattern; advancing through 'b' must fail (set Complete) instead of
	// consuming it.
	fsm2, _ := CompileStructuredFSM("[a]")
	fsm2.Advance('a')
	if !fsm2.Complete {
		t.Error("[a] should be complete after consuming the single 'a'")
	}
	fsm3, _ := CompileStructuredFSM("[a]")
	fsm3.Advance('b')
	if !fsm3.Complete {
		t.Error("[a] should be broken by 'b' (soft enforcement sets Complete)")
	}
}

// TestStructuredFSM_ClassRangeStillWorks confirms the [a-z]/[A-Z]/[0-9] ranges
// still match after removing the shorthand checks (they are expanded to
// per-rune transitions at compile time).
func TestStructuredFSM_ClassRangeStillWorks(t *testing.T) {
	fsm, err := CompileStructuredFSM("[a-c1]")
	if err != nil {
		t.Fatalf("CompileStructuredFSM: %v", err)
	}
	for _, ch := range []rune{'a', 'b', 'c', '1'} {
		if !fsm.canAdvance(ch) {
			t.Errorf("canAdvance(%q) should be true for [a-c1]", ch)
		}
	}
	for _, ch := range []rune{'d', 'z', '0', '2', 'A'} {
		if fsm.canAdvance(ch) {
			t.Errorf("canAdvance(%q) should be false for [a-c1]", ch)
		}
	}
}

// TestSampleFromLogits_TinyTempNoNaN guards against a tiny positive temperature
// overflowing l/temperature to +Inf, which made l-maxLogit a NaN, the softmax
// distribution all-NaN, and (because NaN <= 0 is false) the greedy fallback was
// skipped, silently returning a wrong fixed token instead of the argmax.
func TestSampleFromLogits_TinyTempNoNaN(t *testing.T) {
	logits := []float32{0.1, 9.0, 0.5}
	got := sampleFromLogits(logits, 1e-9, 0.0, 0, 0, nil, 0, nil)
	if got != 1 { // argmax of the (finite) logits is index 1
		t.Errorf("tiny temperature: expected greedy fallback to argmax index 1, got %d", got)
	}
}

// TestSampleFromLogits_MaskDoesNotMutateLock ensures applying a structured-output
// mask does not clobber the caller's logits slice (a reused buffer must remain
// intact for a subsequent unmasked sample).
func TestSampleFromLogits_MaskDoesNotMutateLock(t *testing.T) {
	logits := []float32{0.1, 0.9, 0.5}
	orig := make([]float32, len(logits))
	copy(orig, logits)
	mask := []bool{true, false, true} // index 1 masked out
	sampleFromLogits(logits, 0.7, 0.0, 0, 0, nil, 0, mask)
	for i := range logits {
		if logits[i] != orig[i] {
			t.Fatalf("mask mutated caller logits[%d]: got %v want %v", i, logits, orig)
		}
	}
}

// R35-B regression: the standard (non-chunked) prefill path must account
// dispatch records in the reported stats, like chunked prefill and the
// generation loop do. Before the fix Generate discarded the prefill records,
// so TotalDispatches/MoEDispatches/KVStoreOps reflected only the generation
// tokens and a longer prompt reported identical numbers to a shorter one.
func TestR35PrefillStatsCollected(t *testing.T) {
	modelDir := filepath.Join(SimDir(), "examples", "gemma4_test_synthetic")
	if _, err := os.Stat(filepath.Join(modelDir, "config.json")); err != nil {
		t.Skip("gemma4_test_synthetic model not found")
	}
	run := func(prompt string) *InferenceStats {
		client, err := NewLLMClient(LLMConfig{
			ModelDir:  modelDir,
			Dims:      Dims{Layers: 4, Bx: 4, By: 4},
			MaxTokens: 1,
			DataType:  CUTypeBF16FMA,
		})
		if err != nil {
			t.Fatalf("NewLLMClient: %v", err)
		}
		if _, err := client.Generate(prompt); err != nil {
			t.Fatalf("Generate(%q): %v", prompt, err)
		}
		return &client.Stats
	}
	short := run("alpha")
	long := run("alpha beta gamma")
	if long.TotalDispatches <= short.TotalDispatches {
		t.Errorf("prefill stats not collected: TotalDispatches long=%d short=%d (want long > short)",
			long.TotalDispatches, short.TotalDispatches)
	}
	if long.PrefillTokens != 3 {
		t.Errorf("PrefillTokens=%d want 3", long.PrefillTokens)
	}
}

// TestStructuredFSM_TokenMaskReachability pins the whole-token reachability
// fix for TokenMask: a mask built from a mid-pattern state must never admit a
// token that leaves the FSM in a state from which no vocabulary token can
// complete the pattern. On the synthetic token_N vocabulary the 4-digit serial
// pattern [t][o][k][e][n]_[0-9][0-9][0-9][0-9] used to admit token_444 (the
// walk lands one digit short of accepting with no token able to supply the
// last digit), soft-terminating structured generation one class early with a
// non-conforming output.
func TestStructuredFSM_TokenMaskReachability(t *testing.T) {
	tokens := make([]string, 10000)
	for i := range tokens {
		tokens[i] = fmt.Sprintf("token_%d", i)
	}
	vocab := NewVocabulary(tokens, nil)
	fsm, err := CompileStructuredFSM("[t][o][k][e][n]_[0-9][0-9][0-9][0-9]")
	if err != nil {
		t.Fatalf("CompileStructuredFSM: %v", err)
	}
	mask := fsm.TokenMask(vocab)
	if mask == nil {
		t.Fatal("TokenMask returned nil for an incomplete FSM")
	}
	// From the start state every admitted token must either complete the
	// pattern or land on a completable state. Concretely, 3-digit tokens
	// like token_444 (consumes t,o,k,e,n,_,4,4,4 -- one digit short of
	// accepting) must NOT be admitted; a full 4-digit token is a valid
	// completion.
	for id, ok := range mask {
		if !ok {
			continue
		}
		tok := vocab.IDToToken[id]
		end, oc := fsm.walkFrom(fsm.Current, tok)
		if oc != walkComplete && !fsm.compStates[end] {
			t.Errorf("mask admits %q which dead-ends the pattern (end=%d)", tok, end)
		}
	}
	if !mask[1234] {
		t.Error("token_1234 (a full 4-digit completion) should be admitted from the start state")
	}
	if mask[444] {
		t.Error("token_444 (3 digits, one short of accepting, no token can continue) must not be admitted")
	}
}

// TestStructuredFSM_MaskedGenerationConforms drives GenerateStructured on a
// small client fixture and checks the generated output conforms to the
// pattern: every generated token matches token_[0-9]{4} (or the mask
// degenerated, which the test forbids here because a 4-digit-completable
// vocabulary exists).
func TestStructuredFSM_MaskedGenerationConforms(t *testing.T) {
	dir, err := filepath.Abs(filepath.Join(SimDir(), "examples", "mini_glm_moe"))
	if err != nil {
		t.Fatal(err)
	}
	client, err := NewLLMClient(LLMConfig{
		ModelDir:  dir,
		Dims:      Dims{Layers: 1, Bx: 2, By: 2},
		MaxTokens: 8,
	})
	if err != nil {
		t.Fatalf("NewLLMClient: %v", err)
	}
	ids, err := client.GenerateStructured("issue a four digit token id", "[t][o][k][e][n]_[0-9][0-9][0-9][0-9]")
	if err != nil {
		t.Fatalf("GenerateStructured: %v", err)
	}
	if len(ids) == 0 {
		t.Fatal("GenerateStructured produced no tokens")
	}
	re := regexp.MustCompile(`^token_[0-9]{4}$`)
	for _, id := range ids {
		tok, ok := client.Vocab.IDToToken[id]
		if !ok {
			t.Fatalf("unknown token id %d", id)
		}
		if !re.MatchString(tok) {
			t.Errorf("structured output %q does not match token_[0-9]{4}", tok)
		}
	}
}
