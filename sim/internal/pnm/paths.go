package pnm

import (
	"os"
	"path/filepath"
)

// SiblingRepo locates a directory that sits next to the harness, in either
// the monorepo layout or the published split-repo layout:
//
//	monorepo:  Paper/sim   ->  Paper/HDL,  Paper/fw
//	split:     PNM-sim     ->  PNM-HDL,    PNM-fw
//
// name is the monorepo directory name ("HDL", "fw"). The split repos are
// tried second, so a monorepo checkout always wins when both exist. The
// environment overrides PNM_HDL_DIR / PNM_FW_DIR take precedence.
func SiblingRepo(name string) string {
	root := filepath.Dir(SimDir())
	if v := os.Getenv("PNM_" + upperName(name) + "_DIR"); v != "" {
		if filepath.IsAbs(v) {
			return v
		}
		return filepath.Join(root, v)
	}
	mono := filepath.Join(root, name)
	if _, err := os.Stat(mono); err == nil {
		return mono
	}
	split := filepath.Join(root, "PNM-"+name)
	if _, err := os.Stat(split); err == nil {
		return split
	}
	return mono
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
