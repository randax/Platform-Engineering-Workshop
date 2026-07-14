package main

// Grafana deep links. grafana/otel-lgtm provisions its datasources with
// stable uids ("prometheus", "tempo"), so a link that opens Explore with a
// query prefilled is just a URL — a plain <a>, no iframe embedding, no
// Grafana API. GRAFANA_URL must be the address the *browser* can reach
// (the NodePort), not the cluster-internal service.

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

func grafanaBase() string {
	return strings.TrimSuffix(envOr("GRAFANA_URL", "http://localhost:30030"), "/")
}

// grafanaExplore links to Grafana Explore with the datasource and query
// expression prefilled (Grafana's `panes` URL parameter is just JSON).
func grafanaExplore(datasourceUID, expr string) string {
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
	return grafanaBase() + "/explore?schemaVersion=1&orgId=1&panes=" + url.QueryEscape(string(b))
}

// grafanaTraces opens a TraceQL search for one service's spans in Tempo.
func grafanaTraces(serviceName string) string {
	return grafanaExplore("tempo", fmt.Sprintf(`{resource.service.name=%q}`, serviceName))
}
