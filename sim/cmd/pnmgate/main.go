// pnmgate — hardware-gated real-weights inference harness.
//
// Runs the real Gemma-4 checkpoint with selected MoE layers routed by the
// RTL Gating ASIC (HDL/core/gating_asic.v) under vvp:
//
//	load gating network into ram  : real router.proj.weight rows streamed over
//	                                the ASIC register bus into moe_gating SRAM
//	run it on the gating asic     : gating FSM computes all expert logits +
//	                                top-k in BF16, bit-exact vs the fused-FMA
//	                                oracle
//	feed output to the network    : the ASIC logits feed the engine's softmax
//	                                -> top-k -> normalized weights -> MoE; with
//	                                -network the selected experts are also
//	                                dispatched as flits over the node-network
//	                                fabric RTL (byte-exact delivery verified)
//	rest of inference             : all other ops run on the CPU over the real
//	                                weights; stop token ends generation
//
// Usage:
//
//	pnmgate -model /data/gemma4_dl/complete -layers 0 -width 256 \
//	        -max-tokens 8 "What is the capital of Germany"
//	pnmgate -model /data/ai/models/gemma-4-26b-a4b-it-bf16-fused \
//	        -layers 0 -width 256 -network "Hello"
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"pnm/sim/internal/pnm"
)

func main() {
	model := flag.String("model", "/data/gemma4_dl/complete", "checkpoint directory")
	layers := flag.String("layers", "0", "comma-separated layers routed by the ASIC")
	width := flag.Int("width", 2816, "ASIC projection width (0 or >hidden = full; 256 = paper gating-SRAM width)")
	maxTok := flag.Int("max-tokens", 0, "maximum generated tokens (0 = run until the stop token <turn|>/<eos>, safety-capped)")
	temp := flag.Float64("temp", 0, "sampling temperature (0 = greedy)")
	runDir := flag.String("run-dir", "/tmp/pnmgate", "scratch directory for ASIC I/O")
	prefillLast := flag.Bool("prefill-last", true, "gate only the final prefill position")
	think := flag.Bool("think", false, "print the model's reasoning trace (<|channel>thought ... <channel|>) separately from the answer")
	keep := flag.Bool("keep", false, "keep per-request ASIC I/O files")
	verbose := flag.Bool("v", false, "verbose ASIC logging")
	network := flag.Bool("network", false, "after gating, dispatch the ASIC's selected experts over the node-network fabric RTL and verify byte-exact delivery")
	netLayers := flag.Int("net-layers", 0, "chassis layers for the network proof (0 = cover the gated layers)")
	netBx := flag.Int("net-bx", 4, "chassis board-x for the network proof")
	netBy := flag.Int("net-by", 4, "chassis board-y for the network proof")
	netSeed := flag.Int64("net-seed", 1, "deterministic seed for node resident weights")
	netReplays := flag.Int("net-replays", 1, "fabric determinism replays")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: pnmgate [flags] \"prompt\"\n\n")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() < 1 {
		flag.Usage()
		os.Exit(2)
	}
	prompt := strings.Join(flag.Args(), " ")

	var ls []int
	for _, s := range strings.Split(*layers, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		v, err := strconv.Atoi(s)
		if err != nil {
			fmt.Fprintf(os.Stderr, "bad layer %q: %v\n", s, err)
			os.Exit(2)
		}
		ls = append(ls, v)
	}

	vocab, err := pnm.LoadBPEVocab(filepath.Join(*model, "tokenizer.json"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "tokenizer: %v\n", err)
		os.Exit(1)
	}

	lastRoute := map[int][]int{}
	cfg := pnm.GatingConfig{
		RunDir:      *runDir,
		Layers:      ls,
		Width:       *width,
		PrefillLast: *prefillLast,
		Verbose:     *verbose,
		KeepFiles:   *keep,
		OnRoute: func(layer int, topk []int) {
			lastRoute[layer] = topk
		},
	}

	fmt.Printf("prompt: %q\n", prompt)
	fmt.Printf("gating asic: layers=%v width=%d prefill-last=%v think=%v network=%v\n", ls, *width, *prefillLast, *think, *network)

	if *think {
		t0 := time.Now()
		text, reason, ids, err := pnm.RealGatedThinking(*model, pnm.Dims{}, prompt, *maxTok, vocab, float32(*temp), cfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "gated inference: %v\n", err)
			os.Exit(1)
		}
		el := time.Since(t0)
		fmt.Printf("reasoning: %q\n", reason)
		fmt.Printf("answer: %q\n", text)
		fmt.Printf("tokens: %v\n", ids)
		benchPrint(el, len(ids))
	} else {
		t0 := time.Now()
		text, ids, err := pnm.RealGatedGenerate(*model, pnm.Dims{}, prompt, *maxTok, vocab, float32(*temp), cfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "gated inference: %v\n", err)
			os.Exit(1)
		}
		el := time.Since(t0)
		fmt.Printf("answer: %q\n", text)
		fmt.Printf("tokens: %v\n", ids)
		benchPrint(el, len(ids))
	}
	for _, l := range ls {
		if r, ok := lastRoute[l]; ok {
			fmt.Printf("asic L%d final top-k experts: %v\n", l, r)
		}
	}

	if *network {
		if err := runNetwork(lastRoute, vocab, prompt, *netLayers, *netBx, *netBy, *netSeed, *netReplays); err != nil {
			fmt.Fprintf(os.Stderr, "network: %v\n", err)
			os.Exit(1)
		}
	}
}

// benchPrint emits a wall-clock benchmark line for the gated generation.
func benchPrint(elapsed time.Duration, tokens int) {
	secs := elapsed.Seconds()
	rate := 0.0
	if secs > 0 && tokens > 0 {
		rate = float64(tokens) / secs
	}
	fmt.Printf("bench: %d tokens in %.1fs (%.2f tok/s); wall clock on the scalar-CPU forward, not the silicon rate\n", tokens, secs, rate)
}

// runNetwork dispatches the ASIC's selected experts over the node-network
// fabric RTL and verifies byte-exact delivery to the expert nodes.
func runNetwork(decisions map[int][]int, vocab *pnm.BPEVocab, prompt string,
	nl, bx, by int, seed int64, replays int) error {
	if len(decisions) == 0 {
		return fmt.Errorf("no ASIC routing decisions captured (need at least one gated layer)")
	}
	if nl <= 0 {
		maxL := 0
		for l := range decisions {
			if l > maxL {
				maxL = l
			}
		}
		nl = maxL + 1
	}
	dims := pnm.Dims{Layers: nl, Bx: bx, By: by}
	payload := pnm.PromptPayload(vocab, prompt)
	fcfg := pnm.GatedFabricConfig{Dims: dims, Seed: seed, Replays: replays}

	res, err := pnm.BuildGatedFabricProgram(decisions, payload, fcfg)
	if err != nil {
		return err
	}
	fmt.Printf("network: chassis %s, token payload=%x...\n", dims, payload[:8])
	fmt.Printf("network: dispatching %d expert flit(s) over the node network (X/Y grid)\n", res.PlannedDFlits)

	sr, ok := pnm.RunGatedFabric(res, fcfg)
	if sr == nil {
		return fmt.Errorf("fabric simulation did not run")
	}
	fmt.Printf("network: %d packets, %d doorbell activations, %d DMA bytes, latency min/mean/max %d/%d/%d cyc\n",
		sr.Packets, sr.Activations, sr.DmaBytes, sr.LatencyMin, sr.LatencyMean, sr.LatencyMax)
	if !ok {
		return fmt.Errorf("byte-exact delivery FAILED: %v", sr.Errors)
	}
	fmt.Println("network: PASS — ASIC-selected experts dispatched over the node network, byte-exact to the expert nodes")
	return nil
}
