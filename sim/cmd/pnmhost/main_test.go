package main

import (
	"fmt"
	"strings"
	"testing"
)

// TestParseGlobalKeepsFrag guards against -frag being silently stripped by
// parseGlobal.  Previously parseGlobal consumed "-frag" and its value and
// dropped them, so the subcommand loops in runWorkload/runAuto could never see
// the flag and always fell back to the workload default fragment size.
func TestParseGlobalKeepsFrag(t *testing.T) {
	positional, _ := parseGlobal([]string{"matvec", "-frag", "16", "-l", "4"})

	// The subcommand must still find -frag and its value in the positional list.
	found := false
	for i, a := range positional {
		if a == "-frag" && i+1 < len(positional) {
			if positional[i+1] != "16" {
				t.Errorf("-frag value = %q, want '16'", positional[i+1])
			}
			found = true
		}
	}
	if !found {
		t.Errorf("-frag not preserved in positional list; got %v", positional)
	}

	// Other flags must still be parsed into the config.
	positional2, cfg2 := parseGlobal([]string{"matvec", "-frag", "32", "-y", "8"})
	if cfg2.By != 8 {
		t.Errorf("By = %d, want 8", cfg2.By)
	}
	if len(positional2) != 3 || positional2[0] != "matvec" {
		t.Errorf("positional = %v, want [matvec -frag 32]", positional2)
	}
}

// TestWorkloadFragExtraction verifies the extraction loop that runWorkload uses
// actually recovers the fragment size now that parseGlobal preserves -frag.
func TestWorkloadFragExtraction(t *testing.T) {
	remaining := []string{"matvec", "-frag", "64", "-l", "4"}
	frag := 0
	for i, a := range remaining {
		if a == "-frag" && i+1 < len(remaining) {
			if _, err := fmt.Sscanf(remaining[i+1], "%d", &frag); err != nil {
				t.Fatalf("Sscanf: %v", err)
			}
			remaining = append(remaining[:i], remaining[i+2:]...)
			break
		}
	}
	if frag != 64 {
		t.Errorf("frag = %d, want 64", frag)
	}
	if strings.Join(remaining, " ") != "matvec -l 4" {
		t.Errorf("remaining = %v, want [matvec -l 4]", remaining)
	}
}
