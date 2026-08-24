package web

import (
	"strings"
	"testing"
)

func TestGrafanaLinks(t *testing.T) {
	u := grafanaExplore("http://grafana.cloudbox.k8s.test", "victoriametrics", `up{job="x"}`)
	if !strings.HasPrefix(u, "http://grafana.cloudbox.k8s.test/explore?") {
		t.Errorf("unexpected base: %s", u)
	}
	if strings.ContainsAny(u[len("http://grafana.cloudbox.k8s.test/explore?"):], `{}"`) {
		t.Errorf("query JSON not URL-escaped: %s", u)
	}
	tr := grafanaTraces("http://grafana.cloudbox.k8s.test", "cloudbox-uploader")
	if !strings.Contains(tr, "victoriatraces") {
		t.Error("trace link must target the victoriatraces (Jaeger) datasource")
	}
	if strings.ContainsAny(tr[len("http://grafana.cloudbox.k8s.test/explore?"):], `{}"`) {
		t.Errorf("trace query JSON not URL-escaped: %s", tr)
	}
}
