package web

import (
	"strings"
	"testing"
)

func TestGrafanaLinks(t *testing.T) {
	u := grafanaExplore("http://localhost:30030", "victoriametrics", `up{job="x"}`)
	if !strings.HasPrefix(u, "http://localhost:30030/explore?") {
		t.Errorf("unexpected base: %s", u)
	}
	if strings.ContainsAny(u[len("http://localhost:30030/explore?"):], `{}"`) {
		t.Errorf("query JSON not URL-escaped: %s", u)
	}
	tr := grafanaTraces("http://localhost:30030", "cloudbox-uploader")
	if !strings.Contains(tr, "victoriatraces") {
		t.Error("trace link must target the victoriatraces (Jaeger) datasource")
	}
	if strings.ContainsAny(tr[len("http://localhost:30030/explore?"):], `{}"`) {
		t.Errorf("trace query JSON not URL-escaped: %s", tr)
	}
}
