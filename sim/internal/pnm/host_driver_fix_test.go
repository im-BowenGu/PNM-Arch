package pnm

import (
	"fmt"
	"path/filepath"
	"testing"
)

// TestR35RunModelReportsFailures verifies that a model whose boot loop or
// weight verification recorded errors is reported as FAILED (returns false
// and appends to Result.Errors), never as a spurious OK.
func TestR35RunModelReportsFailures(t *testing.T) {
	modelDir := filepath.Join("..", "..", "examples", "gemma4_test_synthetic")

	// (1) A model with a clean boot loop is reported OK.
	hd := NewHostDriver(HostConfig{Layers: 2, Bx: 2, By: 2})
	if !hd.RunModel(modelDir) {
		t.Fatalf("baseline RunModel should succeed on gemma4")
	}
	if len(hd.Result.Errors) != 0 {
		t.Fatalf("baseline: unexpected Result.Errors: %v", hd.Result.Errors)
	}

	// (2) A model whose weight verification fails must return false, not a
	//     spurious OK. Drive the exact RunModel boot path with a per-node
	//     budget small enough that VerifyWeightUpload fails.
	hd2 := NewHostDriver(HostConfig{Layers: 2, Bx: 2, By: 2})
	drv, err := NewDriver(DriverConfig{ModelDir: modelDir, Dims: hd2.Dims})
	if err != nil {
		t.Fatalf("NewDriver: %v", err)
	}
	drv.MC.PerNodeBudget = 1 // force weight-verify failure

	mr := ModelResult{Dir: modelDir, Nodes: hd2.Cfg.Layers * hd2.Cfg.Bx * hd2.Cfg.By}
	fw := drv.FW
	for phase := 0; phase < 5; phase++ {
		cmds, err := fw.BootPhase()
		if err != nil {
			t.Fatalf("boot phase %d: %v", phase+1, err)
		}
		if phase == 2 {
			if err := fw.VerifyWeightUpload(cmds); err != nil {
				mr.Errors = append(mr.Errors, fmt.Sprintf("weight verify: %v", err))
			}
		}
	}
	if len(mr.Errors) == 0 {
		t.Fatalf("precondition: tiny budget should fail weight verification")
	}
	if ok := hd2.finishModel(modelDir, &mr); ok {
		t.Fatalf("finishModel returned true despite %d recorded errors: %v",
			len(mr.Errors), mr.Errors)
	}
	if len(hd2.Result.Errors) == 0 {
		t.Fatalf("finishModel must append a failure to Result.Errors")
	}
	last := hd2.Result.Models[len(hd2.Result.Models)-1]
	if len(last.Errors) == 0 {
		t.Fatalf("recorded ModelResult must carry the errors")
	}
}