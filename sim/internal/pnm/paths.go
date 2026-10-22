package pnm

import (
	"os"
	"path/filepath"
)

// SiblingRepo locates a directory that sits next to the harness:
//
//	Paper/sim   ->  Paper/HDL,  Paper/fw
//
// name is the directory name ("HDL", "fw"). The environment overrides
// PNM_HDL_DIR / PNM_FW_DIR take precedence, for a checkout that keeps the
// components somewhere else.
func SiblingRepo(name string) string {
	root := filepath.Dir(SimDir())
	if v := os.Getenv("PNM_" + upperName(name) + "_DIR"); v != "" {
		if filepath.IsAbs(v) {
			return v
		}
		return filepath.Join(root, v)
	}
	return filepath.Join(root, name)
}

// upperName turns "HDL" into "HDL" and "fw" into "FW" for the env var name.
func upperName(s string) string {
	out := make([]rune, 0, len(s))
	for _, r := range s {
		if r >= 'a' && r <= 'z' {
			r = r - 'a' + 'A'
		}
		out = append(out, r)
	}
	return string(out)
}
