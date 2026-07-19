package web

// The per-component Monitoring detail page (#56) — "click a component, see its
// telemetry", the Monitoring-tab pattern every cloud console has. Everything on
// it is plain HTTP: metrics from VictoriaMetrics (/api/v1/query_range), a recent
// log tail from VictoriaLogs (/select/logsql/query), and a Grafana deep-link for
// the deep/historical view. No charting library — the sparklines are hand-rolled
// inline SVG (internal/metrics.Sparkline).

import (
	"fmt"
	"html/template"
	"net/http"
	"time"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/logs"
	"cloudbox.io/portal/internal/metrics"
)

type componentDetailData struct {
	Name        string
	Namespace   string
	Description string
	Ready       int
	Total       int
	Status      string
	StatusClass string // health dot/badge: ok | meh | bad | off

	// Diagnostics — the "why" (DR-0005), shown only when the component isn't
	// Operational: the failing pods' container states + recent Warning events.
	Diag     kube.Diagnostics
	ShowDiag bool

	// Case file — the agent investigation affordance (module 10), offered when
	// this component is unhealthy. Closes the seam where lab faults (the demo
	// namespace's workloads) had no path into the Console. Same shared "case-file"
	// template as the Application detail.
	CaseFile caseFile

	// Monitoring — populated only when the observability stack is running
	// (the per-component "unlock": no telemetry, no panel — just a hint).
	Telemetry  bool
	CPUSpark   template.HTML
	MemSpark   template.HTML
	CPUNow     string
	MemNow     string
	Logs       []logs.Line
	MetricsURL string // Grafana Explore deep-link (deep/historical view)
}

func handleComponentDetail(s *Server, w http.ResponseWriter, r *http.Request) {
	ns := r.PathValue("namespace")
	if !kube.ValidName(ns) {
		http.NotFound(w, r)
		return
	}
	// Only cataloged components get a detail page — the title/description come
	// from the same fixed list the Components page renders.
	var comp *component
	for i := range componentCatalog {
		if componentCatalog[i].Namespace == ns {
			comp = &componentCatalog[i]
			break
		}
	}
	if comp == nil {
		http.NotFound(w, r)
		return
	}

	health, err := s.Kube.NamespaceWorkloads(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	h := health[ns]
	data := componentDetailData{
		Name: comp.Title, Namespace: ns, Description: comp.Description,
		Ready: h.Ready, Total: h.Total,
	}
	switch {
	case h.Total == 0:
		data.Status, data.StatusClass = "Not installed", "off"
	case h.Ready == h.Total:
		data.Status, data.StatusClass = "Operational", "ok"
	case h.Ready > 0:
		data.Status, data.StatusClass = "Degraded", "meh"
	default:
		data.Status, data.StatusClass = "Down", "bad"
	}

	// Diagnose the cause when the component isn't fully healthy (DR-0005) — the
	// failing pods and Warning events for its namespace. Best-effort: a diag read
	// error never breaks the page, it just leaves the section empty (hidden).
	unhealthy := h.Total > 0 && h.Ready < h.Total
	if unhealthy {
		if diag, derr := s.Kube.NamespaceDiagnostics(r.Context(), ns); derr == nil {
			data.Diag = diag
			data.ShowDiag = !diag.Empty()
		}
	}
	// Offer the Case file agent investigation on an unhealthy component (module
	// 10) — the path lab faults (the demo workloads) take into the Console. Kind
	// "Component" keeps this session distinct from any Application named like the
	// namespace. The resource name is the namespace itself: a DNS-valid identifier
	// the /agent/ask contract accepts, and the agent's evidence comes from that
	// namespace's diagnostics rollup regardless.
	data.CaseFile = caseFileFor(s, unhealthy, "Component", ns, ns)

	// Gate the Monitoring panel on the observability stack actually running —
	// no point querying VM/VLogs (and paying their timeouts) when nothing is
	// collecting. This is the per-component unlock the PRD describes.
	if health["observability"].Ready > 0 {
		data.Telemetry = true
		data.MetricsURL = grafanaExplore(s.GrafanaURL, "victoriametrics", metrics.NamespaceCPUQuery(ns))
		if s.Prom != nil {
			if cpu, _ := s.Prom.QueryRange(r.Context(), metrics.NamespaceCPUQuery(ns)); len(cpu) > 0 {
				data.CPUSpark = metrics.Sparkline(cpu, "CPU usage")
				data.CPUNow = fmt.Sprintf("%.3f cores", cpu[len(cpu)-1])
			}
			if mem, _ := s.Prom.QueryRange(r.Context(), metrics.NamespaceMemQuery(ns)); len(mem) > 0 {
				data.MemSpark = metrics.Sparkline(mem, "memory working set")
				data.MemNow = humanBytes(mem[len(mem)-1])
			}
		}
		if s.Logs != nil {
			data.Logs, _ = s.Logs.Tail(r.Context(), logs.NamespaceFilter(ns), time.Hour, 40)
		}
	}
	s.render(w, "component-detail", data)
}

// humanBytes formats a byte count as a compact KiB/MiB/GiB string for the
// "current value" beside a memory sparkline.
func humanBytes(b float64) string {
	const unit = 1024.0
	switch {
	case b >= unit*unit*unit:
		return fmt.Sprintf("%.1f GiB", b/(unit*unit*unit))
	case b >= unit*unit:
		return fmt.Sprintf("%.0f MiB", b/(unit*unit))
	case b >= unit:
		return fmt.Sprintf("%.0f KiB", b/unit)
	default:
		return fmt.Sprintf("%.0f B", b)
	}
}
