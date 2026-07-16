package metrics

// Package metrics: sparklines without a charting stack. The teaching beat of this file: a
// metrics chart is one HTTP GET (Prometheus's /api/v1/query_range) and some
// SVG — that is what every real console does behind much more machinery.

import (
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type Client struct {
	base string
	http *http.Client
}

func New(promURL string) *Client {
	return &Client{
		base: strings.TrimSuffix(promURL, "/"),
		// Short timeout: a sparkline is decoration, never worth a slow page.
		http: &http.Client{Timeout: 3 * time.Second},
	}
}

// RequestRateQuery builds the PromQL for a service's request rate. otelhttp
// (v0.61, HTTP semconv v1.26) exports the OTLP histogram
// `http.server.request.duration` in seconds, which VictoriaMetrics stores (with
// -opentelemetry.usePrometheusNaming) as http_server_request_duration_seconds_*.
// The OTel service.name ("cloudbox-uploader", …) arrives as a *resource
// attribute*, and VM maps those to underscore labels — so it's `service_name`,
// NOT the Prometheus `job` (confirmed against VM: k8s.namespace.name likewise
// lands as k8s_namespace_name). rate() of the _count series = req/s.
func RequestRateQuery(service string) string {
	return fmt.Sprintf(`sum(rate(http_server_request_duration_seconds_count{service_name=%q}[5m]))`, service)
}

// LatencyAvgQuery builds the PromQL for a service's mean request latency from
// the SAME otelhttp histogram RequestRateQuery uses: rate(_sum) / rate(_count).
// This deliberately avoids histogram_quantile/_bucket — VictoriaMetrics stores
// OTLP histogram buckets with its native `vmrange` label, not Prometheus `le`,
// so a `sum by (le)` p95 comes back empty. The mean is robust and needs only
// the _sum/_count series (both present). Result is in seconds. (A true p95 via
// VM's vmrange buckets is a follow-up.)
func LatencyAvgQuery(service string) string {
	return fmt.Sprintf(
		`sum(rate(http_server_request_duration_seconds_sum{service_name=%q}[5m])) / sum(rate(http_server_request_duration_seconds_count{service_name=%q}[5m]))`,
		service, service)
}

// NamespaceCPUQuery / NamespaceMemQuery sum a namespace's pod resource usage —
// the universal per-component Monitoring signal (#56). The source is the
// kubeletstats receiver's k8s.pod.cpu.usage / k8s.pod.memory.working_set, which
// VictoriaMetrics stores (with -opentelemetry.usePrometheusNaming) under the
// names below, labelled by the k8s.namespace.name resource attribute →
// k8s_namespace_name. sum() collapses the per-pod series into one line.
func NamespaceCPUQuery(namespace string) string {
	return fmt.Sprintf(`sum(k8s_pod_cpu_usage{k8s_namespace_name=%q})`, namespace)
}

func NamespaceMemQuery(namespace string) string {
	return fmt.Sprintf(`sum(k8s_pod_memory_working_set_bytes{k8s_namespace_name=%q})`, namespace)
}

// QueryRange fetches the last 30 minutes of a PromQL expression at 60s
// resolution and returns just the values. No matching series is a normal
// state (component disabled, no traffic yet) and returns nil, nil — the
// caller renders a "no metrics yet" dash, never an error.
func (p *Client) QueryRange(ctx context.Context, query string) ([]float64, error) {
	end := time.Now()
	params := url.Values{
		"query": {query},
		"start": {strconv.FormatInt(end.Add(-30*time.Minute).Unix(), 10)},
		"end":   {strconv.FormatInt(end.Unix(), 10)},
		"step":  {"60"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		p.base+"/api/v1/query_range?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := p.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var body struct {
		Status string `json:"status"`
		Data   struct {
			Result []struct {
				Values [][2]any `json:"values"` // pairs of [unix-time, "value"]
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	if body.Status != "success" || len(body.Data.Result) == 0 {
		return nil, nil // no series: not an error, just nothing to draw
	}
	var vals []float64
	for _, pair := range body.Data.Result[0].Values {
		s, _ := pair[1].(string)
		v, _ := strconv.ParseFloat(s, 64)
		vals = append(vals, v)
	}
	return vals, nil
}

// Sparkline turns a series into one inline SVG <polyline> — hand-rolled,
// ~25 lines, zero dependencies. `label` is the accessible description (what the
// line measures). Returns "" for missing data so templates can show their
// empty-state dash instead. preserveAspectRatio="none" lets CSS stretch it to
// fill its container (e.g. a full-width metric card) instead of letterboxing.
func Sparkline(vals []float64, label string) template.HTML {
	if len(vals) < 2 {
		return ""
	}
	const w, h, pad = 120.0, 28.0, 2.0
	maxV := 0.0
	for _, v := range vals {
		if v > maxV {
			maxV = v
		}
	}
	if maxV == 0 {
		maxV = 1 // an idle service still gets its flat line
	}
	var pts strings.Builder
	for i, v := range vals {
		x := pad + float64(i)*(w-2*pad)/float64(len(vals)-1)
		y := h - pad - (v/maxV)*(h-2*pad)
		fmt.Fprintf(&pts, "%.1f,%.1f ", x, y)
	}
	svg := fmt.Sprintf(
		`<svg class="spark" viewBox="0 0 %.0f %.0f" width="%.0f" height="%.0f" preserveAspectRatio="none" role="img" aria-label="%s, last 30 minutes"><polyline points="%s" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>`,
		w, h, w, h, template.HTMLEscapeString(label), strings.TrimSpace(pts.String()))
	return template.HTML(svg) // safe: numbers we computed + an escaped label
}
