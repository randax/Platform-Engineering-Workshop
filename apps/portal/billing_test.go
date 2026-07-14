package main

import "testing"

func TestParseCPU(t *testing.T) {
	cases := map[string]int64{
		"100m": 100, "2": 2000, "1500m": 1500, "0.5": 500, "": 0,
	}
	for in, want := range cases {
		if got := parseCPU(in); got != want {
			t.Errorf("parseCPU(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestParseMem(t *testing.T) {
	cases := map[string]int64{
		"256Mi": 256 << 20,
		"1Gi":   1 << 30,
		"512Ki": 512 << 10,
		"500M":  500_000_000,
		"1024":  1024,
		"":      0,
	}
	for in, want := range cases {
		if got := parseMem(in); got != want {
			t.Errorf("parseMem(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestNodeUsagePct(t *testing.T) {
	n := nodeUsage{CPUReq: 1500, CPUAlloc: 4000, MemReq: 0, MemAlloc: 0}
	if n.CPUPct() != 37 {
		t.Errorf("CPUPct = %d, want 37", n.CPUPct())
	}
	if n.MemPct() != 0 { // zero allocatable must not divide by zero
		t.Errorf("MemPct = %d, want 0", n.MemPct())
	}
}
