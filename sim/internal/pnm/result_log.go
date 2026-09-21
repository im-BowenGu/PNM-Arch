package pnm

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
)

// ScenarioResult holds all measurable output for one simulation scenario.
type ScenarioResult struct {
	Name          string                 `json:"name"            csv:"scenario"`
	Nodes         int                    `json:"nodes"           csv:"nodes"`
	Layers        int                    `json:"layers"          csv:"layers"`
	WireBytes     int                    `json:"wire_bytes"      csv:"wire_bytes"`
	Pass          bool                   `json:"pass"            csv:"pass"`
	Activations   int                    `json:"activations"     csv:"activations"`
	Rejections    int                    `json:"rejections"      csv:"rejections"`
	Packets       int                    `json:"packets"         csv:"packets"`
	DmaBytes      int                    `json:"dma_bytes"       csv:"dma_bytes"`
	Slices        int                    `json:"slices"          csv:"slices"`
	WorstSpanCyc  int                    `json:"worst_span_cyc"  csv:"worst_span_cyc"`
	BytesPerCycle float64                `json:"bytes_per_cycle"  csv:"bytes_per_cycle"`
	LatencyMin    int                    `json:"latency_min_cyc"  csv:"latency_min_cyc"`
	LatencyMean   int                    `json:"latency_mean_cyc" csv:"latency_mean_cyc"`
	LatencyMax    int                    `json:"latency_max_cyc"  csv:"latency_max_cyc"`
	Latencies     []int                  `json:"-"               csv:"-"`
	NodeResults   map[string]interface{} `json:"-" csv:"-"` // node -> verified kernel results (node ID string keys)
	Errors        []string               `json:"errors,omitempty" csv:"-"`
}

// RunResult aggregates results across all scenarios in a test run.
type RunResult struct {
	Dims      Dims             `json:"dims"`
	Seed      int64            `json:"seed"`
	Scenarios []ScenarioResult `json:"scenarios"`
	AllPass   bool             `json:"all_pass"`
}

// TokenResult holds generated token output.
type TokenResult struct {
	Prompt    string `json:"prompt"`
	Tokens    []int  `json:"token_ids"`
	Text      string `json:"text"`
	PromptLen int    `json:"prompt_length"`
	GenLen    int    `json:"generated_length"`
}

// DispatchResult holds a structured dispatch record for CSV/JSON export.
type DispatchResult struct {
	Step       int    `json:"step"        csv:"step"`
	Layer      int    `json:"layer"       csv:"layer"`
	Phase      string `json:"phase"       csv:"phase"`
	TargetNode string `json:"target_node" csv:"target_node"`
	ExpertIdx  int    `json:"expert_idx"  csv:"expert_idx"`
	FlitBytes  int    `json:"flit_bytes"  csv:"flit_bytes"`
	CUType     string `json:"cu_type"     csv:"cu_type"`
	KVAction   string `json:"kv_action"   csv:"kv_action"`
}

// InferenceResult holds the complete output of an LLM inference run.
type InferenceResult struct {
	Tokens     TokenResult      `json:"tokens"`
	Stats      map[string]int   `json:"stats"`
	Dispatches []DispatchResult `json:"dispatches,omitempty"`
}

// WriteScenarioCSV writes per-scenario results to a CSV file.
func WriteScenarioCSV(path string, results []ScenarioResult) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("result_log: create %s: %w", path, err)
	}
	defer f.Close()

	w := csv.NewWriter(f)
	defer w.Flush()

	header := []string{
		"scenario", "nodes", "layers", "wire_bytes", "pass",
		"activations", "rejections", "packets", "dma_bytes",
		"slices", "worst_span_cyc", "bytes_per_cycle",
		"latency_min_cyc", "latency_mean_cyc", "latency_max_cyc",
	}
	if err := w.Write(header); err != nil {
		return err
	}

	for _, r := range results {
		row := []string{
			r.Name,
			strconv.Itoa(r.Nodes),
			strconv.Itoa(r.Layers),
			strconv.Itoa(r.WireBytes),
			strconv.FormatBool(r.Pass),
			strconv.Itoa(r.Activations),
			strconv.Itoa(r.Rejections),
			strconv.Itoa(r.Packets),
			strconv.Itoa(r.DmaBytes),
			strconv.Itoa(r.Slices),
			strconv.Itoa(r.WorstSpanCyc),
			fmt.Sprintf("%.2f", r.BytesPerCycle),
			strconv.Itoa(r.LatencyMin),
			strconv.Itoa(r.LatencyMean),
			strconv.Itoa(r.LatencyMax),
		}
		if err := w.Write(row); err != nil {
			return err
		}
	}
	return nil
}

// WriteScenarioJSON writes per-scenario results to a JSON file.
func WriteScenarioJSON(path string, result *RunResult) error {
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("result_log: marshal: %w", err)
	}
	return os.WriteFile(path, data, 0o644)
}

// WriteLatencyCSV writes per-packet latency data to a CSV file.
func WriteLatencyCSV(path string, results []ScenarioResult) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("result_log: create %s: %w", path, err)
	}
	defer f.Close()

	w := csv.NewWriter(f)
	defer w.Flush()

	if err := w.Write([]string{"scenario", "packet_index", "latency_cycles"}); err != nil {
		return err
	}

	for _, r := range results {
		for i, lat := range r.Latencies {
			if err := w.Write([]string{
				r.Name,
				strconv.Itoa(i),
				strconv.Itoa(lat),
			}); err != nil {
				return err
			}
		}
	}
	return nil
}

// WriteTokensFile writes generated tokens as text to a file.
func WriteTokensFile(path string, result *TokenResult) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("result_log: create tokens file: %w", err)
	}
	defer f.Close()

	fmt.Fprintf(f, "# PNM Inference Output\n")
	fmt.Fprintf(f, "# Prompt length: %d tokens\n", result.PromptLen)
	fmt.Fprintf(f, "# Generated: %d tokens\n\n", result.GenLen)
	fmt.Fprintf(f, "--- Prompt ---\n%s\n\n", result.Prompt)
	fmt.Fprintf(f, "--- Generated ---\n%s\n", result.Text)
	fmt.Fprintf(f, "\n--- Token IDs ---\n")
	for i, id := range result.Tokens {
		if i > 0 {
			fmt.Fprintf(f, " ")
		}
		fmt.Fprintf(f, "%d", id)
	}
	fmt.Fprintf(f, "\n")
	return nil
}

// WriteInferenceJSON writes the complete inference result to a JSON file.
func WriteInferenceJSON(path string, result *InferenceResult) error {
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("result_log: marshal inference: %w", err)
	}
	return os.WriteFile(path, data, 0o644)
}

// WriteDispatchCSV writes the dispatch plan to a CSV file.
func WriteDispatchCSV(path string, records []DispatchResult) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("result_log: create dispatch file: %w", err)
	}
	defer f.Close()

	w := csv.NewWriter(f)
	defer w.Flush()

	header := []string{"step", "layer", "phase", "target_node", "expert_idx", "flit_bytes", "cu_type", "kv_action"}
	if err := w.Write(header); err != nil {
		return err
	}

	for _, r := range records {
		row := []string{
			strconv.Itoa(r.Step),
			strconv.Itoa(r.Layer),
			r.Phase,
			r.TargetNode,
			strconv.Itoa(r.ExpertIdx),
			strconv.Itoa(r.FlitBytes),
			r.CUType,
			r.KVAction,
		}
		if err := w.Write(row); err != nil {
			return err
		}
	}
	return nil
}

// DispatchRecordsToResults converts firmware dispatch records to exportable form.
func DispatchRecordsToResults(records []DispatchRecord) []DispatchResult {
	out := make([]DispatchResult, len(records))
	for i, r := range records {
		out[i] = DispatchResult{
			Step:       i,
			Layer:      r.Layer,
			Phase:      r.Phase,
			TargetNode: r.TargetNode.String(),
			ExpertIdx:  r.ExpertIdx,
			FlitBytes:  r.FlitBytes,
			CUType:     fmt.Sprintf("%d", r.CUType),
			KVAction:   r.KVAction,
		}
	}
	return out
}

// InferenceStatsToMap converts InferenceStats to a flat map for JSON export.
func InferenceStatsToMap(s *InferenceStats) map[string]int {
	return map[string]int{
		"tokens_generated":      s.TokensGenerated,
		"prefill_tokens":        s.PrefillTokens,
		"total_layers":          s.TotalLayers,
		"total_dispatches":      s.TotalDispatches,
		"total_flits":           s.TotalFlits,
		"moe_dispatches":        s.MoEDispatches,
		"dense_dispatches":      s.DenseDispatches,
		"kv_store_ops":          s.KVStoreOps,
		"kv_load_ops":           s.KVLoadOps,
		"kv_evictions":          s.KVEvictions,
		"flash_attn_dispatches": s.FlashAttnDispatches,
		"chunked_prefill_ops":   s.ChunkedPrefillOps,
		"batch_schedules":       s.BatchSchedules,
		"speculative_drafts":    s.SpeculativeDrafts,
		"speculative_accepts":   s.SpeculativeAccepts,
		"prefix_cache_hits":     s.PrefixCacheHits,
		"repeat_kv_ops":         s.RepeatKVOps,
	}
}

// WriteSummaryCSV writes a single-row summary with all key metrics.
func WriteSummaryCSV(path string, result *RunResult) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("result_log: create summary: %w", err)
	}
	defer f.Close()

	w := csv.NewWriter(f)
	defer w.Flush()

	// Collect all unique scenario names for column headers
	scNames := make([]string, 0, len(result.Scenarios))
	for _, s := range result.Scenarios {
		scNames = append(scNames, s.Name)
	}
	sort.Strings(scNames)

	// Build header: fixed columns + per-scenario latency columns
	header := []string{"layers", "bx", "by", "nodes", "seed", "all_pass"}
	for _, sc := range scNames {
		header = append(header, sc+"_pass", sc+"_span", sc+"_bpc", sc+"_lat_min", sc+"_lat_mean", sc+"_lat_max")
	}
	if err := w.Write(header); err != nil {
		return err
	}

	// Build row
	row := []string{
		strconv.Itoa(result.Dims.Layers),
		strconv.Itoa(result.Dims.Bx),
		strconv.Itoa(result.Dims.By),
		strconv.Itoa(result.Dims.Layers * result.Dims.Bx * result.Dims.By),
		strconv.FormatInt(result.Seed, 10),
		strconv.FormatBool(result.AllPass),
	}

	// Index scenarios by name for lookup
	scMap := make(map[string]ScenarioResult, len(result.Scenarios))
	for _, s := range result.Scenarios {
		scMap[s.Name] = s
	}

	for _, sc := range scNames {
		s := scMap[sc]
		row = append(row,
			strconv.FormatBool(s.Pass),
			strconv.Itoa(s.WorstSpanCyc),
			fmt.Sprintf("%.2f", s.BytesPerCycle),
			strconv.Itoa(s.LatencyMin),
			strconv.Itoa(s.LatencyMean),
			strconv.Itoa(s.LatencyMax),
		)
	}

	return w.Write(row)
}

// EnsureOutputDir creates the output directory if it doesn't exist.
func EnsureOutputDir(dir string) error {
	if dir == "" {
		return nil
	}
	return os.MkdirAll(dir, 0o755)
}

// OutputPaths returns standard output file paths for a given base directory and run name.
func OutputPaths(dir, name string) (csvPath, jsonPath, latCSV, sumCSV string) {
	if dir == "" {
		dir = "."
	}
	base := filepath.Join(dir, name)
	return base + "_results.csv",
		base + "_results.json",
		base + "_latency.csv",
		base + "_summary.csv"
}

// SortedKeys returns the keys of a map in sorted order.
func sortedMapKeys(m map[string]int) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
