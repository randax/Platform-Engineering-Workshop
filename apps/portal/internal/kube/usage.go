package kube

// Node capacity accounting for the Billing page: container requests summed
// per node against allocatable, straight from the API server — no
// metrics-server required. Includes just enough of a Kubernetes quantity
// parser for a lab cluster.

import (
	"context"
	"fmt"
	"strconv"
	"strings"
)

type NodeUsage struct {
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

func (n NodeUsage) CPUPct() int { return pct(n.CPUReq, n.CPUAlloc) }
func (n NodeUsage) MemPct() int { return pct(n.MemReq, n.MemAlloc) }
func (n NodeUsage) CPUText() string {
	return fmt.Sprintf("%dm of %dm requested", n.CPUReq, n.CPUAlloc)
}
func (n NodeUsage) MemText() string {
	return fmt.Sprintf("%.1f GiB of %.1f GiB requested",
		float64(n.MemReq)/(1<<30), float64(n.MemAlloc)/(1<<30))
}

// ParseCPU turns a Kubernetes CPU quantity ("100m", "2") into millicores.
func ParseCPU(q string) int64 {
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

// ParseMem turns a memory quantity ("256Mi", "1Gi", "500M") into bytes —
// just the suffixes that actually occur on a lab cluster.
func ParseMem(q string) int64 {
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

// NodeUsages joins two lists the portal already knows how to fetch: nodes
// (allocatable capacity) and pods (per-container requests, grouped by the
// node they run on).
func (k *Client) NodeUsages(ctx context.Context) ([]NodeUsage, error) {
	var nodeList struct {
		Items []struct {
			Metadata ObjMeta `json:"metadata"`
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

	byNode := map[string]*NodeUsage{}
	var order []string
	for _, n := range nodeList.Items {
		byNode[n.Metadata.Name] = &NodeUsage{
			Name:     n.Metadata.Name,
			CPUAlloc: ParseCPU(n.Status.Allocatable["cpu"]),
			MemAlloc: ParseMem(n.Status.Allocatable["memory"]),
		}
		order = append(order, n.Metadata.Name)
	}
	for _, p := range podList.Items {
		u, ok := byNode[p.Spec.NodeName]
		if !ok || p.Status.Phase == "Succeeded" || p.Status.Phase == "Failed" {
			continue // finished pods hold no requests
		}
		for _, c := range p.Spec.Containers {
			u.CPUReq += ParseCPU(c.Resources.Requests["cpu"])
			u.MemReq += ParseMem(c.Resources.Requests["memory"])
		}
	}

	usages := make([]NodeUsage, 0, len(order))
	for _, name := range order {
		usages = append(usages, *byNode[name])
	}
	return usages, nil
}
