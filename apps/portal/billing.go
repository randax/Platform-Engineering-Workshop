package main

// The Billing page — the sovereignty punchline, rendered with a straight
// face. The usage numbers are real: container requests summed per node
// against the node's allocatable capacity, straight from the API server
// (no metrics-server, no billing export, no FinOps tooling). The prices
// are the point.

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type nodeUsage struct {
	Name     string
	CPUReq   int64 // millicores requested by scheduled pods
	CPUAlloc int64 // millicores allocatable
	MemReq   int64 // bytes requested
	MemAlloc int64 // bytes allocatable
}

func pct(part, whole int64) int {
	if whole == 0 {
		return 0
	}
	return int(part * 100 / whole)
}

func (n nodeUsage) CPUPct() int { return pct(n.CPUReq, n.CPUAlloc) }
func (n nodeUsage) MemPct() int { return pct(n.MemReq, n.MemAlloc) }
func (n nodeUsage) CPUText() string {
	return fmt.Sprintf("%dm of %dm requested", n.CPUReq, n.CPUAlloc)
}
func (n nodeUsage) MemText() string {
	return fmt.Sprintf("%.1f GiB of %.1f GiB requested",
		float64(n.MemReq)/(1<<30), float64(n.MemAlloc)/(1<<30))
}

// parseCPU turns a Kubernetes CPU quantity ("100m", "2") into millicores.
func parseCPU(q string) int64 {
	if q == "" {
		return 0
	}
	if strings.HasSuffix(q, "m") {
		v, _ := strconv.ParseInt(strings.TrimSuffix(q, "m"), 10, 64)
		return v
	}
	v, _ := strconv.ParseFloat(q, 64)
	return int64(v * 1000)
}

// parseMem turns a memory quantity ("256Mi", "1Gi", "500M") into bytes —
// just the suffixes that actually occur on a lab cluster.
func parseMem(q string) int64 {
	if q == "" {
		return 0
	}
	units := []struct {
		suffix string
		factor int64
	}{
		{"Ti", 1 << 40}, {"Gi", 1 << 30}, {"Mi", 1 << 20}, {"Ki", 1 << 10},
		{"T", 1e12}, {"G", 1e9}, {"M", 1e6}, {"k", 1e3},
	}
	for _, u := range units {
		if strings.HasSuffix(q, u.suffix) {
			v, _ := strconv.ParseFloat(strings.TrimSuffix(q, u.suffix), 64)
			return int64(v * float64(u.factor))
		}
	}
	v, _ := strconv.ParseInt(q, 10, 64)
	return v
}

// nodeUsages joins two lists the portal already knows how to fetch: nodes
// (allocatable capacity) and pods (per-container requests, grouped by the
// node they run on).
func (k *kubeClient) nodeUsages(ctx context.Context) ([]nodeUsage, error) {
	var nodeList struct {
		Items []struct {
			Metadata objMeta `json:"metadata"`
			Status   struct {
				Allocatable map[string]string `json:"allocatable"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := k.get(ctx, "/api/v1/nodes", &nodeList); err != nil {
		return nil, err
	}

	var podList struct {
		Items []struct {
			Spec struct {
				NodeName   string `json:"nodeName"`
				Containers []struct {
					Resources struct {
						Requests map[string]string `json:"requests"`
					} `json:"resources"`
				} `json:"containers"`
			} `json:"spec"`
			Status struct {
				Phase string `json:"phase"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := k.get(ctx, "/api/v1/pods", &podList); err != nil {
		return nil, err
	}

	byNode := map[string]*nodeUsage{}
	var order []string
	for _, n := range nodeList.Items {
		byNode[n.Metadata.Name] = &nodeUsage{
			Name:     n.Metadata.Name,
			CPUAlloc: parseCPU(n.Status.Allocatable["cpu"]),
			MemAlloc: parseMem(n.Status.Allocatable["memory"]),
		}
		order = append(order, n.Metadata.Name)
	}
	for _, p := range podList.Items {
		u, ok := byNode[p.Spec.NodeName]
		if !ok || p.Status.Phase == "Succeeded" || p.Status.Phase == "Failed" {
			continue // finished pods hold no requests
		}
		for _, c := range p.Spec.Containers {
			u.CPUReq += parseCPU(c.Resources.Requests["cpu"])
			u.MemReq += parseMem(c.Resources.Requests["memory"])
		}
	}

	usages := make([]nodeUsage, 0, len(order))
	for _, name := range order {
		usages = append(usages, *byNode[name])
	}
	return usages, nil
}

// ---------------------------------------------------------------- handler

type billingData struct {
	Month   string
	Nodes   []nodeUsage
	DBCount int
}

func (s *server) handleBilling(w http.ResponseWriter, r *http.Request) {
	nodes, err := s.kube.nodeUsages(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	dbCount := 0
	if dbs, err := s.kube.listWorkshopDatabases(r.Context()); err == nil {
		dbCount = len(dbs)
	}
	s.render(w, "billing", billingData{
		Month:   time.Now().Format("January 2006"),
		Nodes:   nodes,
		DBCount: dbCount,
	})
}
