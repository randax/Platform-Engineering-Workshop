package web

// Grafana deep links. The Victoria-stack Grafana provisions its datasources
// with stable uids ("victoriametrics", "victorialogs", "victoriatraces"), so a
// link that opens Explore with a query prefilled is just a URL — a plain <a>,
// no iframe embedding, no Grafana API. The base URL must be the address the
// *browser* can reach (the NodePort), not the cluster-internal service.

import (
	"encoding/json"
	"net/url"
	"strings"
)

// grafanaExplore links to Grafana Explore with the datasource and query
// expression prefilled (Grafana's `panes` URL parameter is just JSON).
func grafanaExplore(base, datasourceUID, expr string) string {
	pane := map[string]any{
		"a": map[string]any{
			"datasource": datasourceUID,
			"queries": []map[string]any{{
				"refId":      "A",
				"datasource": map[string]string{"uid": datasourceUID},
				"expr":       expr,
			}},
		},
	}
	b, _ := json.Marshal(pane)
	return strings.TrimSuffix(base, "/") + "/explore?schemaVersion=1&orgId=1&panes=" + url.QueryEscape(string(b))
}

// grafanaTraces opens a search for one service's spans in VictoriaTraces via
// Grafana's built-in Jaeger datasource (VictoriaTraces speaks the Jaeger query
// API, not Tempo/TraceQL — see gitops/components/victoria-traces/VENDOR.md).
// The Jaeger query model uses queryType+service, not an `expr`, so this builds
// its own pane rather than reusing grafanaExplore.
func grafanaTraces(base, serviceName string) string {
	pane := map[string]any{
		"a": map[string]any{
			"datasource": "victoriatraces",
			"queries": []map[string]any{{
				"refId":      "A",
				"datasource": map[string]string{"uid": "victoriatraces", "type": "jaeger"},
				"queryType":  "search",
				"service":    serviceName,
			}},
		},
	}
	b, _ := json.Marshal(pane)
	return strings.TrimSuffix(base, "/") + "/explore?schemaVersion=1&orgId=1&panes=" + url.QueryEscape(string(b))
}
