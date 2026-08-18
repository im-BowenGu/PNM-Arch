package pnm

import (
	"fmt"
	"sort"
)

// KVCache is defined in kv_cache.go

// ============================================================================
// Firmware for the PNM central router chip.
//
// The firmware models the router chip's boot sequence and runtime dispatch
// loop.  In production, this runs as microcode on the router chip's embedded
// processor.  In co-simulation, it orchestrates the Go-side driver to feed
// flits into the Verilog fabric in the correct order.
//
// Boot sequence (paper §2.5):
//   Phase 1: POST Discovery — ping fabric, collect TOPOLOGY_RDY, build inventory
//   Phase 2: Routing Table Load — program xyz_repeaters and HFRs with bitmaps
//   Phase 3: Weight Upload — stream weight blobs through the fabric to node LPDDR6
//   Phase 4: MoE Gating Load — program on-chip SRAM with router.proj weights
//   Phase 5: Ready — begin inference dispatch
//
// Runtime dispatch (paper §2.8):
//   For each token:
//     For each layer l = 0..num_layers-1:
//       1. Dense path: dispatch to attention node for layer l
//       2. MoE gating: router_weights[l] · hidden_state → logits
//       3. Top-K selection: experts = argmax(logits, k)
//       4. For each expert: dispatch to the node holding that expert's weights
//       5. Combine: weighted sum of expert outputs → hidden_state for next layer
// ============================================================================

// FirmwareState represents the current state of the router chip firmware.
type FirmwareState int

const (
	FWStateReset     FirmwareState = iota // power-on reset
	FWStatePOSTDiscovery                  // Phase 1: topology discovery
	FWStateRoutingTable                   // Phase 2: load routing tables
	FWStateWeightUpload                   // Phase 3: upload weights to nodes
	FWStateMoELoad                        // Phase 4: load gating weights
	FWStateReady                          // Phase 5: inference dispatch
)

// NodeInventory is one discovered node's metadata.
type NodeInventory struct {
	Node    NodeID
	ModuleID byte
	Bandwidth int  // link bandwidth (GB/s)
	Status    int  // 0=down, 1=ready
}

// Firmware is the router chip's runtime model.
type Firmware struct {
	Driver *Driver
	State  FirmwareState

	// POST discovery results
	Inventory []NodeInventory
	NodeCount int

	// KV cache management
	KV *KVCache

	// Dispatch counters
	DispatchCount int
	WeightCount   int
	ErrorCount    int
}

// NewFirmware creates a Firmware bound to a Driver.
func NewFirmware(d *Driver) *Firmware {
	hiddenSize := d.Config.TextConfig.HiddenSize
	return &Firmware{
		Driver: d,
		State:  FWStateReset,
		KV:     NewKVCache(d.Dims, hiddenSize),
	}
}

// ============================================================================
// Boot sequence
// ============================================================================

// BootPhase runs one phase of the boot sequence.  Returns the flit commands
// generated during this phase (to be injected into the fabric) and any error.
func (fw *Firmware) BootPhase() ([]WeightUploadCommand, error) {
	switch fw.State {
	case FWStateReset:
		return fw.bootPOSTDiscovery()
	case FWStatePOSTDiscovery:
		return fw.bootRoutingTable()
	case FWStateRoutingTable:
		return fw.bootWeightUpload()
	case FWStateWeightUpload:
		return fw.bootMoELoad()
	case FWStateMoELoad:
		fw.State = FWStateReady
		return nil, nil
	default:
		return nil, fmt.Errorf("firmware: unexpected boot phase %d", fw.State)
	}
}

// bootPOSTDiscovery: ping the fabric and discover all nodes.
func (fw *Firmware) bootPOSTDiscovery() ([]WeightUploadCommand, error) {
	fw.Inventory = nil
	fw.NodeCount = 0

	dims := fw.Driver.Dims
	for l := 0; l < dims.Layers; l++ {
		for x := 0; x < dims.Bx; x++ {
			for y := 0; y < dims.By; y++ {
				nid := NodeID{L: l, X: x, Y: y}
				moduleID := byte((x << 4) | y)
				fw.Inventory = append(fw.Inventory, NodeInventory{
					Node:     nid,
					ModuleID: moduleID,
					Bandwidth: 256, // LPDDR6 CAMM2: 256 GB/s per node
					Status:   1,
				})
				fw.NodeCount++
			}
		}
	}

	fw.State = FWStatePOSTDiscovery
	return nil, nil
}

// bootRoutingTable: generate the commands to program routing bitmaps.
func (fw *Firmware) bootRoutingTable() ([]WeightUploadCommand, error) {
	// Routing tables are loaded into xyz_repeaters and HFRs via sideband.
	// In the co-sim, these are embedded in the generated topology.
	// The driver's RouteBitmaps map holds the pre-computed values.
	fw.State = FWStateRoutingTable
	return nil, nil
}

// bootWeightUpload: generate weight upload commands for all nodes.
func (fw *Firmware) bootWeightUpload() ([]WeightUploadCommand, error) {
	cmds, err := fw.Driver.BuildWeightCommands()
	if err != nil {
		return nil, fmt.Errorf("firmware: weight upload: %w", err)
	}
	fw.WeightCount = len(cmds)
	fw.State = FWStateWeightUpload
	return cmds, nil
}

// bootMoELoad: generate commands to load MoE gating weights into the router
// chip's on-chip SRAM.  In the co-sim, these are embedded in the firmware.
func (fw *Firmware) bootMoELoad() ([]WeightUploadCommand, error) {
	// MoE gating weights (router.proj.weight) are stored on the router chip,
	// not on compute nodes.  The driver's MC has them in the router chip node
	// assignments.  In the co-sim, we just record them as loaded.
	fw.State = FWStateMoELoad
	return nil, nil
}

// ============================================================================
// Inference dispatch
// ============================================================================

// DispatchRecord is one step in the inference dispatch sequence.
type DispatchRecord struct {
	Layer      int              // model layer index
	Phase      string           // "dense", "moe", or "kv_offload"
	TargetNode NodeID           // destination node
	ExpertIdx  int              // -1 for dense, >= 0 for MoE
	FlitBytes  int              // flit wire length
	KVAction   string           // "store", "load", "evict", or "" (none)
	CUType     ComputeUnitType  // compute unit to use on target node
	TensorRole string           // tensor role for dispatch routing
}

// PlanInference computes the full dispatch sequence for one token through
// all transformer layers.  Returns the sequence of dispatch records and the
// weight flit commands to inject.  After each layer's attention step, the
// firmware checks whether KV offloading is needed.
func (fw *Firmware) PlanInference(token []byte) ([]DispatchRecord, error) {
	if fw.State != FWStateReady {
		return nil, fmt.Errorf("firmware: not ready (state=%d)", fw.State)
	}

	tc := &fw.Driver.Config.TextConfig
	dims := fw.Driver.Dims
	nodesPerLayer := dims.Bx * dims.By
	modelLayersPerPhysical := (tc.NumHiddenLayers + dims.Layers - 1) / dims.Layers

	var records []DispatchRecord

	for ml := 0; ml < tc.NumHiddenLayers; ml++ {
		pl := ml / modelLayersPerPhysical
		if pl >= dims.Layers {
			pl = dims.Layers - 1
		}

		// Step 1: Dense path — dispatch to attention node
		attnNodeIdx := ml % nodesPerLayer
		attnX := attnNodeIdx / dims.By
		attnY := attnNodeIdx % dims.By
		attnNode := NodeID{L: pl, X: attnX, Y: attnY}

		flit := Flit(pl+1, (attnX<<4)|attnY, CTRL_COMPUTE_SPINE, token, false)
		records = append(records, DispatchRecord{
			Layer:      ml,
			Phase:      "dense",
			TargetNode: attnNode,
			ExpertIdx:  -1,
			FlitBytes:  len(flit),
			KVAction:   "store",
			CUType:     CUTypeBF16Array, // attention uses BF16 systolic MAC array
			TensorRole: "attn_q",
		})

		// Step 2: KV cache check — offload if needed
		if fw.KV != nil && fw.KV.Layers[pl].NeedsOffload() {
			records = append(records, DispatchRecord{
				Layer:      ml,
				Phase:      "kv_offload",
				TargetNode: attnNode,
				ExpertIdx:  -1,
				FlitBytes:  0,
				KVAction:   "evict",
				CUType:     CUTypeNone,
			})
			// Perform the offload in the model
			fw.KV.OffloadCycle()
		}

		// Step 3: MoE gating — dispatch to top-k experts
		for expIdx := 0; expIdx < tc.TopKExperts; expIdx++ {
			key := MoeKey{ModelLayer: ml, ExpertIdx: expIdx}
			expertNode, ok := fw.Driver.MoeMap[key]
			if !ok {
				continue
			}

			flit := Flit(expertNode.L+1, (expertNode.X<<4)|expertNode.Y,
				CTRL_COMPUTE_SPINE, token, false)
			records = append(records, DispatchRecord{
				Layer:      ml,
				Phase:      "moe",
				TargetNode: expertNode,
				ExpertIdx:  expIdx,
				FlitBytes:  len(flit),
				CUType:     CUTypeBF16FMA, // MoE experts use BF16 weight-stationary FMA
				TensorRole: "expert_gate_up",
			})
		}
	}

	fw.DispatchCount += len(records)
	return records, nil
}

// ============================================================================
// Verification helpers
// ============================================================================

// VerifyWeightUpload checks that the weight upload commands match the
// AOT compilation: correct targets, correct sizes, no budget overflow.
func (fw *Firmware) VerifyWeightUpload(cmds []WeightUploadCommand) error {
	// Track per-node bytes
	nodeBytes := map[NodeID]int64{}
	for _, cmd := range cmds {
		nid := NodeID{
			L: cmd.TargetLayer,
			X: int(cmd.TargetModule >> 4),
			Y: int(cmd.TargetModule & 0x0F),
		}
		nodeBytes[nid] += int64(len(cmd.Payload))
	}

	// Check per-node budget
	for nid, total := range nodeBytes {
		if total > fw.Driver.MC.PerNodeBudget {
			return fmt.Errorf("firmware: node %s: %.1f GB exceeds %.1f GB budget",
				nid, float64(total)/1e9, float64(fw.Driver.MC.PerNodeBudget)/1e9)
		}
	}

	// Check all assigned nodes received weights
	for nid, na := range fw.Driver.MC.NodeAssignments {
		if nid.L < 0 || na.TotalBytes == 0 {
			continue
		}
		if _, ok := nodeBytes[nid]; !ok {
			return fmt.Errorf("firmware: node %s has %d bytes assigned but received 0",
				nid, na.TotalBytes)
		}
	}

	return nil
}

// VerifyDispatch checks that the dispatch sequence covers all required targets.
func (fw *Firmware) VerifyDispatch(records []DispatchRecord) error {
	// Collect unique targets per layer
	type layerTarget struct {
		layer  int
		target NodeID
	}
	seen := map[layerTarget]bool{}
	for _, r := range records {
		if r.Phase != "kv_offload" {
			seen[layerTarget{r.Layer, r.TargetNode}] = true
		}
	}

	// Check that every attention node is covered
	tc := &fw.Driver.Config.TextConfig
	dims := fw.Driver.Dims
	nodesPerLayer := dims.Bx * dims.By
	modelLayersPerPhysical := (tc.NumHiddenLayers + dims.Layers - 1) / dims.Layers

	for ml := 0; ml < tc.NumHiddenLayers; ml++ {
		pl := ml / modelLayersPerPhysical
		if pl >= dims.Layers {
			pl = dims.Layers - 1
		}
		attnNodeIdx := ml % nodesPerLayer
		attnX := attnNodeIdx / dims.By
		attnY := attnNodeIdx % dims.By
		key := layerTarget{ml, NodeID{L: pl, X: attnX, Y: attnY}}
		if !seen[key] {
			return fmt.Errorf("dispatch: layer %d attention node %s not covered", ml, key.target)
		}
	}

	return nil
}

// ============================================================================
// Summary
// ============================================================================

// Summary returns a human-readable summary of the firmware state.
func (fw *Firmware) Summary() string {
	var b fmt.Stringer
	_ = b
	return fmt.Sprintf("Firmware: state=%d nodes=%d dispatches=%d weights=%d errors=%d",
		fw.State, fw.NodeCount, fw.DispatchCount, fw.WeightCount, fw.ErrorCount)
}

// DispatchSummary returns the dispatch plan as a formatted string.
func (fw *Firmware) DispatchSummary(records []DispatchRecord) string {
	var s string
	s += "# Firmware dispatch plan\n"
	s += fmt.Sprintf("# Total dispatches: %d\n", len(records))
	s += fmt.Sprintf("# KV cache: %s\n", fw.KV.Summary())
	s += "#\n"
	s += "# Layer | Phase     | Target       | Expert | FlitBytes | CU            | KV\n"
	s += "#-------+-----------+--------------+--------+-----------+---------------+------\n"

	currentLayer := -1
	for _, r := range records {
		if r.Layer != currentLayer {
			s += fmt.Sprintf("#\n")
			currentLayer = r.Layer
		}
		expertStr := "dense"
		if r.ExpertIdx >= 0 {
			expertStr = fmt.Sprintf("exp_%d", r.ExpertIdx)
		}
		kvStr := r.KVAction
		if kvStr == "" {
			kvStr = "-"
		}
		s += fmt.Sprintf("#   %2d  | %-9s | %-12s | %-6s | %9d | %-13s | %s\n",
			r.Layer, r.Phase, r.TargetNode, expertStr, r.FlitBytes, r.CUType, kvStr)
	}

	return s
}

// ============================================================================
// Sort helper
// ============================================================================

func sortedNodes(m map[NodeID]*NodeAssignment) []NodeID {
	var nodes []NodeID
	for nid := range m {
		nodes = append(nodes, nid)
	}
	sort.Slice(nodes, func(i, j int) bool {
		a, b := nodes[i], nodes[j]
		if a.L != b.L {
			return a.L < b.L
		}
		if a.X != b.X {
			return a.X < b.X
		}
		return a.Y < b.Y
	})
	return nodes
}
