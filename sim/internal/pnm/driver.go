package pnm

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// ============================================================================
// Host-side driver for the PNM architecture.
//
// The driver runs on the PCIe-attached CPU and orchestrates:
//   1. Model loading: parse config.json + safetensors index
//   2. Compilation: AOT-compile the model onto the chassis (ModelCompiler)
//   3. Weight upload: stream weight blobs through the router chip to node LPDDR6
//   4. Inference: dispatch tokens through the MoE fabric
//
// In production, steps 3-4 communicate with the router chip over PCIe Gen5 x16.
// In co-simulation, the driver constructs flits directly (bypassing the actual
// PCIe link) and feeds them into the Verilog fabric via the harness.
// ============================================================================

// Driver is the host-side interface to a PNM chassis.
type Driver struct {
	Dims    Dims
	MC      *ModelCompiler
	Config  *ModelConfig
	Index   *SafetensorsIndex
	Tensors map[string]*TensorMeta

	// Routing tables (pre-computed by AOT, loaded into router chip SRAM)
	RouteBitmaps map[NodeID]uint16

	// MoE expert map: (model_layer, expert_idx) → (physical_layer, module_id)
	MoeMap map[MoeKey]NodeID

	// Firmware state
	FW *Firmware
}

// MoeKey identifies one expert in the MoE gating table.
type MoeKey struct {
	ModelLayer int
	ExpertIdx  int
}

// DriverConfig holds the parameters for creating a new Driver.
type DriverConfig struct {
	ModelDir string
	Dims     Dims
}

// NewDriver creates a Driver from a model directory and chassis dimensions.
// It loads the model config, safetensors index, compiles the model, and
// pre-computes routing tables and MoE maps.
func NewDriver(dc DriverConfig) (*Driver, error) {
	// Load model config
	cfg, err := LoadModelConfig(dc.ModelDir)
	if err != nil {
		return nil, fmt.Errorf("driver: loading config: %w", err)
	}

	// Load safetensors index
	idx, err := LoadSafetensorsIndex(dc.ModelDir)
	if err != nil {
		return nil, fmt.Errorf("driver: loading safetensors index: %w", err)
	}

	// Collect tensor metadata
	tensors, _ := CollectTensors(idx, cfg)

	// AOT compile
	mc, err := CompileModel(cfg, idx, dc.Dims)
	if err != nil {
		return nil, fmt.Errorf("driver: compilation: %w", err)
	}

	d := &Driver{
		Dims:    dc.Dims,
		MC:      mc,
		Config:  cfg,
		Index:   idx,
		Tensors: tensors,
	}

	// Pre-compute routing tables
	d.RouteBitmaps = d.computeRouteBitmaps()

	// Pre-compute MoE expert map
	d.MoeMap = d.computeMoeMap()

	// Initialize firmware
	d.FW = NewFirmware(d)

	return d, nil
}

// ============================================================================
// Routing table computation
// ============================================================================

// computeRouteBitmaps generates the 11-bit routing bitmap for every node.
// Bitmap format (pnm_defs.vh):
//   [10:7] LAYER (4b, 1-based), [6] AXIS (0=X), [5] SIGN (0=+), [4:0] DIST
func (d *Driver) computeRouteBitmaps() map[NodeID]uint16 {
	bitmaps := make(map[NodeID]uint16)
	for nid := range d.MC.NodeAssignments {
		if nid.L < 0 {
			continue // skip router chip
		}
		layerBits := uint16(nid.L+1) << 7  // 1-based layer ID
		distBits := uint16(nid.Y) & 0x1F   // Y distance from xyz_repeater
		bitmaps[nid] = layerBits | (1 << 6) | distBits  // bit 6 = Y-axis
	}
	return bitmaps
}

// ============================================================================
// MoE expert map computation
// ============================================================================

// computeMoeMap builds the expert→coordinate mapping from the AOT compilation.
// For each (model_layer, expert_idx), it records which physical node holds
// that expert's weights.
func (d *Driver) computeMoeMap() map[MoeKey]NodeID {
	m := make(map[MoeKey]NodeID)
	for nid, na := range d.MC.NodeAssignments {
		if nid.L < 0 {
			continue
		}
		for _, t := range na.Tensors {
			if t.Role == "expert_gate_up" {
				key := MoeKey{ModelLayer: t.ModelLayer, ExpertIdx: t.ExpertIdx}
				m[key] = nid
			}
		}
	}
	return m
}

// ============================================================================
// Weight upload protocol
// ============================================================================

// WeightUploadCommand is one weight blob to upload via the router chip.
// Wire format over PCIe:
//
//	CMD(0x01) | LAYER | MODULE | LEN_HI | LEN_LO | payload... | CRC_HI | CRC_LO
type WeightUploadCommand struct {
	TargetLayer  int             // physical layer (0-based)
	TargetModule byte            // MODULE_ID = {X[3:0], Y[3:0]}
	Payload      []byte          // raw tensor bytes
	CUType       ComputeUnitType // compute unit that processes this tensor
	DType        string          // "BF16", "FP16", "FP32", "INT8"
	ModelLayer   int             // model layer index (-1 for non-layer tensors)
	TensorRole   string          // tensor role for dispatch routing
}

// BuildWeightCommands produces the sequence of weight upload commands for
// the entire compiled model.  Each node's tensors are serialized as separate
// commands, preserving the AOT-assigned placement.
func (d *Driver) BuildWeightCommands() ([]WeightUploadCommand, error) {
	var cmds []WeightUploadCommand

	// Sort nodes for deterministic upload order
	var nodes []NodeID
	for nid := range d.MC.NodeAssignments {
		if nid.L < 0 {
			continue
		}
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

	for _, nid := range nodes {
		na := d.MC.NodeAssignments[nid]
		if na.TotalBytes == 0 {
			continue
		}

		moduleID := byte((nid.X << 4) | nid.Y)

		// Group tensors by model layer for ordered upload
		byLayer := map[int][]TensorRef{}
		for _, t := range na.Tensors {
			byLayer[t.ModelLayer] = append(byLayer[t.ModelLayer], t)
		}

		var layerIndices []int
		for ml := range byLayer {
			layerIndices = append(layerIndices, ml)
		}
		sort.Ints(layerIndices)

		for _, ml := range layerIndices {
			for _, t := range byLayer[ml] {
				// Generate synthetic weight bytes (in production, read from safetensors)
				payload := d.generateWeightPayload(t)

				cmds = append(cmds, WeightUploadCommand{
					TargetLayer:  nid.L,
					TargetModule: moduleID,
					Payload:      payload,
					CUType:       t.CUType,
					DType:        t.DType,
					ModelLayer:   t.ModelLayer,
					TensorRole:   t.Role,
				})
			}
		}
	}

	return cmds, nil
}

// generateWeightPayload produces the raw BF16 weight bytes for a tensor.
// In production, this reads from the safetensors file at the correct offset.
// For the co-simulation, it generates deterministic synthetic data.
func (d *Driver) generateWeightPayload(t TensorRef) []byte {
	nbytes := int(t.SizeBytes)
	if nbytes == 0 {
		return nil
	}
	payload := make([]byte, nbytes)
	for i := range payload {
		// Deterministic pattern based on tensor identity
		payload[i] = byte((t.ModelLayer*7 + t.ExpertIdx*3 + i*5) & 0xFF)
	}
	return payload
}

// ============================================================================
// Flit construction (PCIe → spine wormhole flits)
// ============================================================================

// BuildWeightFlit constructs one wormhole flit for a weight upload command.
// Wire layout: LAYER_ID | MODULE_ID | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
func BuildWeightFlit(cmd WeightUploadCommand) []StreamByte {
	layerID := cmd.TargetLayer + 1 // 1-based on the wire
	modID := int(cmd.TargetModule)
	ctrl := CTRL_COMPUTE_SPINE
	return Flit(layerID, modID, ctrl, cmd.Payload, false)
}

// ============================================================================
// Inference API
// ============================================================================

// InferDispatch is one token dispatch through the MoE fabric.
// The driver sends the token to the router chip, which evaluates the gating
// network and dispatches to the top-k experts.
type InferDispatch struct {
	TokenPayload []byte    // input hidden state
}

// PlanInference computes the dispatch sequence for one token through all
// layers.  For each layer: (1) dispatch to the attention node, (2) dispatch
// to each of the top-k experts.
func (d *Driver) PlanInference(token []byte) (*InferDispatch, error) {
	tc := &d.Config.TextConfig
	if tc.NumExperts == 0 {
		return nil, fmt.Errorf("driver: no experts in model config")
	}

	disp := &InferDispatch{
		TokenPayload: token,
	}

	nodesPerLayer := d.Dims.Bx * d.Dims.By
	modelLayersPerPhysical := (tc.NumHiddenLayers + d.Dims.Layers - 1) / d.Dims.Layers

	for ml := 0; ml < tc.NumHiddenLayers; ml++ {
		pl := ml / modelLayersPerPhysical
		if pl >= d.Dims.Layers {
			pl = d.Dims.Layers - 1
		}

		// Dense path: attention node
		attnNodeIdx := ml % nodesPerLayer
		attnX := attnNodeIdx / d.Dims.By
		attnY := attnNodeIdx % d.Dims.By
		_ = NodeID{L: pl, X: attnX, Y: attnY} // dispatch target

		// MoE path: top-k experts (for now, all experts — no gating network)
		for expIdx := 0; expIdx < tc.TopKExperts; expIdx++ {
			key := MoeKey{ModelLayer: ml, ExpertIdx: expIdx}
			if _, ok := d.MoeMap[key]; !ok {
				continue // expert not in map (shouldn't happen)
			}
		}
	}

	return disp, nil
}

// ============================================================================
// Schemas and serialization
// ============================================================================

// RoutingTableSchema is the JSON-serializable routing table for the host driver.
type RoutingTableSchema struct {
	Nodes []RoutingEntrySchema `json:"nodes"`
}

// RoutingEntrySchema is one node's routing entry.
type RoutingEntrySchema struct {
	Layer   int    `json:"layer"`
	X       int    `json:"x"`
	Y       int    `json:"y"`
	Bitmap  uint16 `json:"bitmap"`
	Role    string `json:"role"`
}

// MoeMapSchema is the JSON-serializable MoE expert map.
type MoeMapSchema struct {
	Entries []MoeEntrySchema `json:"entries"`
}

// MoeEntrySchema is one expert's mapping.
type MoeEntrySchema struct {
	ModelLayer   int `json:"model_layer"`
	ExpertIdx    int `json:"expert_idx"`
	PhysicalLayer int `json:"physical_layer"`
	X            int `json:"x"`
	Y            int `json:"y"`
}

// WriteRoutingTable writes the routing table as JSON.
func (d *Driver) WriteRoutingTable(path string) error {
	schema := RoutingTableSchema{}
	for nid, bitmap := range d.RouteBitmaps {
		schema.Nodes = append(schema.Nodes, RoutingEntrySchema{
			Layer:  nid.L,
			X:      nid.X,
			Y:      nid.Y,
			Bitmap: bitmap,
			Role:   "compute",
		})
	}
	sort.Slice(schema.Nodes, func(i, j int) bool {
		a, b := schema.Nodes[i], schema.Nodes[j]
		if a.Layer != b.Layer {
			return a.Layer < b.Layer
		}
		if a.X != b.X {
			return a.X < b.X
		}
		return a.Y < b.Y
	})
	data, err := json.MarshalIndent(schema, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// WriteMoeMap writes the MoE expert map as JSON.
func (d *Driver) WriteMoeMap(path string) error {
	schema := MoeMapSchema{}
	for key, nid := range d.MoeMap {
		schema.Entries = append(schema.Entries, MoeEntrySchema{
			ModelLayer:    key.ModelLayer,
			ExpertIdx:     key.ExpertIdx,
			PhysicalLayer: nid.L,
			X:             nid.X,
			Y:             nid.Y,
		})
	}
	sort.Slice(schema.Entries, func(i, j int) bool {
		a, b := schema.Entries[i], schema.Entries[j]
		if a.ModelLayer != b.ModelLayer {
			return a.ModelLayer < b.ModelLayer
		}
		return a.ExpertIdx < b.ExpertIdx
	})
	data, err := json.MarshalIndent(schema, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// ============================================================================
// Helpers
// ============================================================================

// ModelDir resolves the model directory path relative to the sim/ working dir.
func ModelDir(name string) string {
	d := SimDir()
	return filepath.Join(d, "examples", name)
}
