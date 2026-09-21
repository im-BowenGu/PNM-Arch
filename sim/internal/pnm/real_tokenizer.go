package pnm

// Real-weight inference: a compact, correct-enough forward pass for the
// Gemma-4-26B-A4B checkpoint using the ACTUAL BF16 weights from the
// safetensors shards, plus a byte-fallback BPE tokenizer matching the
// shipped tokenizer.json.  This exists to demonstrate the model actually
// producing text when real weights are present; the dispatch/firmware/fabric
// paths remain the co-simulation artifacts of the paper.

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
)

// ============================================================================
// BPE tokenizer (byte fallback, matching tokenizer.json)
// ============================================================================

type BPEVocab struct {
	IDToToken  []string
	TokenToID  map[string]int
	Merges     []bpeMerge
	BosID      int
	EosID      int
	SpecialIDs map[int]bool
}

type bpeMerge struct {
	left  string
	right string
}

// LoadBPEVocab parses a HuggingFace tokenizer.json (SentencePiece/BPE with
// byte fallback, as shipped for Gemma-4) into a usable table.
func LoadBPEVocab(path string) (*BPEVocab, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc struct {
		Model struct {
			Vocab  map[string]int `json:"vocab"`
			Merges [][]string     `json:"merges"`
		} `json:"model"`
		AddedTokens []struct {
			ID      int    `json:"id"`
			Content string `json:"content"`
		} `json:"added_tokens"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	v := &BPEVocab{
		TokenToID:  make(map[string]int, len(doc.Model.Vocab)),
		SpecialIDs: map[int]bool{},
	}
	// Build id->token (tokens that share an id collapse to the lowest index).
	type tk struct {
		id   int
		name string
	}
	order := make([]tk, 0, len(doc.Model.Vocab))
	for name, id := range doc.Model.Vocab {
		order = append(order, tk{id, name})
	}
	sort.Slice(order, func(i, j int) bool { return order[i].id < order[j].id })
	maxID := -1
	for _, t := range order {
		if t.id > maxID {
			maxID = t.id
		}
	}
	v.IDToToken = make([]string, maxID+1)
	for _, t := range order {
		if v.IDToToken[t.id] == "" {
			v.IDToToken[t.id] = t.name
		}
	}
	for name, id := range doc.Model.Vocab {
		v.TokenToID[name] = id
	}
	for _, at := range doc.AddedTokens {
		if at.ID >= 0 && at.ID < len(v.IDToToken) {
			v.IDToToken[at.ID] = at.Content
		}
		v.TokenToID[at.Content] = at.ID
		v.SpecialIDs[at.ID] = true
	}
	for _, m := range doc.Model.Merges {
		if len(m) == 2 {
			v.Merges = append(v.Merges, bpeMerge{m[0], m[1]})
		}
	}
	// known Gemma specials
	v.BosID = idOr(v.TokenToID, "<bos>", 2)
	v.EosID = idOr(v.TokenToID, "<eos>", 1)
	return v, nil
}

func idOr(m map[string]int, key string, def int) int {
	if v, ok := m[key]; ok {
		return v
	}
	return def
}

// byteFallbackWord converts a 1-char UTF-8 byte-literal token name like
// "<0xE2>" into the sequence's byte value (0..255).
func byteFallbackByte(tok string) (byte, bool) {
	if len(tok) == 6 && strings.HasPrefix(tok, "<0x") && strings.HasSuffix(tok, ">") {
		var b uint32
		if _, err := fmt.Sscanf(tok[3:5], "%02X", &b); err == nil && b < 256 {
			return byte(b), true
		}
	}
	return 0, false
}

// tokenBytes returns the raw byte payload of a vocab token, handling
// byte-fallback tokens (single bytes) and everything else (UTF-8 text).
func (v *BPEVocab) tokenBytes(tok string) []byte {
	if b, ok := byteFallbackByte(tok); ok {
		return []byte{b}
	}
	return []byte(tok)
}

// rankIndex builds a fast merge-rank lookup: pair -> merge rank (lower = earlier).
func (v *BPEVocab) mergeRank(left, right string) (int, bool) {
	for i, m := range v.Merges {
		if m.left == left && m.right == right {
			return i, true
		}
	}
	return 0, false
}

// wordBPE computes the BPE merge sequence for one whitespace-split word,
// returning vocab-token IDs.  Handles byte fallback (tokenizing a subword
// that has no vocab entry by decomposing to bytes) per the Gemma tokenizer.
func (v *BPEVocab) wordBPE(word []byte) ([]int, error) {
	wordStr := string(word)
	// initial segmentation: longest possible vocab tokens? Standard BPE uses
	// single chars; byte-fallback tokenizers first map unknown chars to their
	// byte tokens, and SentencePiece-style BPE splits into byte chars.
	// To be safe and deterministic we implement char-level BPE on bytes with
	// byte-fallback tokens for non-ASCII bytes that have no UTF-8 char token.
	ids := make([]int, 0, len(word))
	// Split into UTF-8 runes; a rune tokenizes to its vocab token if present,
	// else to its UTF-8 bytes as byte-fallback tokens.
	runes := []rune(wordStr)
	for _, r := range runes {
		rStr := string(r)
		id, ok := v.TokenToID[rStr]
		if ok {
			ids = append(ids, id)
			continue
		}
		for _, b := range []byte(rStr) {
			bt := fmt.Sprintf("<0x%02X>", b)
			if bid, ok2 := v.TokenToID[bt]; ok2 {
				ids = append(ids, bid)
			} else {
				return nil, fmt.Errorf("no token for byte %02X of %q", b, rStr)
			}
		}
	}
	// apply merges: repeatedly find the pair with lowest merge rank
	for {
		best := -1
		bestRank := math.MaxInt
		for i := 0; i+1 < len(ids); i++ {
			lt := v.IDToToken[ids[i]]
			rt := v.IDToToken[ids[i+1]]
			// merge only if the merged string exists as a vocab token
			merged := lt + rt
			if _, exists := v.TokenToID[merged]; !exists {
				continue
			}
			rank, ok := v.mergeRank(lt, rt)
			if !ok {
				continue
			}
			if rank < bestRank {
				bestRank = rank
				best = i
			}
		}
		if best < 0 {
			break
		}
		lt := v.IDToToken[ids[best]]
		rt := v.IDToToken[ids[best+1]]
		merged := lt + rt
		mid, ok := v.TokenToID[merged]
		if !ok {
			break
		}
		// replace the pair with the merged token
		newIDs := make([]int, 0, len(ids)-1)
		newIDs = append(newIDs, ids[:best]...)
		newIDs = append(newIDs, mid)
		newIDs = append(newIDs, ids[best+2:]...)
		ids = newIDs
	}
	// verify all tokens exist
	for _, id := range ids {
		if id < 0 || id >= len(v.IDToToken) || v.IDToToken[id] == "" {
			return nil, fmt.Errorf("bpe produced out-of-range token %d", id)
		}
	}
	return ids, nil
}

// Encode runs the full pretokenizer (whitespace split + merge) and BPE.
// It returns token IDs equivalent to HF tokenizers' fast path for normal
// text (no special tokens, no cleanup).
func (v *BPEVocab) Encode(text string) ([]int, error) {
	// Gemma pretokenizer: split on whitespace, attach the supervision marker
	// (SentencePiece style: leading space becomes ▁ on continuation words).
	// We replicate the common result: first word keeps no leading space;
	// subsequent words keep a leading "▁".
	var out []int
	fields := strings.Fields(text)
	offset := 0
	for fi, word := range fields {
		start := strings.Index(text[offset:], word)
		if start < 0 {
			start = 0
		}
		_ = start
		offset += len(word)
		// skip whitespace run
		for offset < len(text) && (text[offset] == ' ' || text[offset] == '\t' || text[offset] == '\n') {
			offset++
		}
		if fi == 0 {
			// first word: no leading marker (SentencePiece normalize).
			// HF BPE pretokenizer keeps words as-is; a following word inherits
			// the preceding whitespace as the continuation prefix.
			w := word
			ids, err := v.wordBPE([]byte(w))
			if err != nil {
				return nil, err
			}
			out = append(out, ids...)
		} else {
			// the tokenizer's pretokenizer emits " ▁word" for words after
			// whitespace (the whitespace becomes the ▁ sentinel).
			w := "\u2581" + word
			ids, err := v.wordBPE([]byte(w))
			if err != nil {
				return nil, err
			}
			out = append(out, ids...)
		}
	}
	return out, nil
}

// Decode converts token IDs back to readable text, handling byte-fallback
// tokens and the ▁ space marker.
func (v *BPEVocab) Decode(ids []int) string {
	var b strings.Builder
	for _, id := range ids {
		if id < 0 || id >= len(v.IDToToken) || v.IDToToken[id] == "" {
			continue
		}
		tok := v.IDToToken[id]
		if bval, ok := byteFallbackByte(tok); ok {
			b.WriteByte(bval)
			continue
		}
		if strings.HasPrefix(tok, "\u2581") {
			if b.Len() > 0 {
				b.WriteByte(' ')
			}
			b.WriteString(strings.TrimPrefix(tok, "\u2581"))
			continue
		}
		b.WriteString(tok)
	}
	return b.String()
}

// ============================================================================
// BF16 / tensor access
// ============================================================================

// bf16ToF32 converts a BF16 (bits) to a float32 value.
func bf16ToF32(b uint16) float32 {
	return math.Float32frombits(uint32(b) << 16)
}

// Tensor is a lazily-loaded BF16 matrix from a safetensors shard.
type Tensor struct {
	Data   []byte   // raw shard bytes for the tensor
	Shape  []int64  // row-major dimensions
	Loaded bool
}

// realModel holds memory-mapped access to the checkpoint's tensors.
type realModel struct {
	dir   string
	desc  map[string]*safetensorsTensorDescriptor
	cache map[string][]byte // name -> raw bytes (loaded on first use)
}

func newRealModel(dir string, desc map[string]*safetensorsTensorDescriptor) *realModel {
	return &realModel{dir: dir, desc: desc, cache: map[string][]byte{}}
}

func (m *realModel) tensorBytes(name string) []byte {
	if b, ok := m.cache[name]; ok {
		return b
	}
	d, ok := m.desc[name]
	if !ok || d == nil {
		return nil
	}
	b := ReadRealTensorBytes(m.dir, d)
	m.cache[name] = b
	return b
}

// at returns flattened value at linear index i (BF16).
func (m *realModel) at(name string, i int64) float32 {
	b := m.tensorBytes(name)
	if b == nil {
		return 0
	}
	return bf16ToF32(binary.LittleEndian.Uint16(b[i*2:]))
}

// vec returns name as float32 slice (row-major).
func (m *realModel) vec(name string) []float32 {
	b := m.tensorBytes(name)
	if b == nil {
		return nil
	}
	n := len(b) / 2
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		out[i] = bf16ToF32(binary.LittleEndian.Uint16(b[i*2:]))
	}
	return out
}

// mat returns name as [rows][cols] float32.
func (m *realModel) mat(name string, rows, cols int) [][]float32 {
	b := m.tensorBytes(name)
	if b == nil {
		return nil
	}
	out := make([][]float32, rows)
	for r := 0; r < rows; r++ {
		out[r] = make([]float32, cols)
		for c := 0; c < cols; c++ {
			idx := (int64(r)*int64(cols) + int64(c)) * 2
			if idx+1 < int64(len(b)) {
				out[r][c] = bf16ToF32(binary.LittleEndian.Uint16(b[idx:]))
			}
		}
	}
	return out
}