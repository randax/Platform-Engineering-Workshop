package web

import (
	"strings"
	"testing"
)

func TestGrafanaLinks(t *testing.T) {
	u := grafanaExplore("http://localhost:30030", "prometheus", `up{job="x"}`)
	if !strings.HasPrefix(u, "http://localhost:30030/explore?") {
		t.Errorf("unexpected base: %s", u)
	}
	if strings.ContainsAny(u[len("http://localhost:30030/explore?"):], `{}"`) {
		t.Errorf("query JSON not URL-escaped: %s", u)
	}
	if !strings.Contains(grafanaTraces("http://localhost:30030", "cloudbox-uploader"), "tempo") {
		t.Error("trace link must target the tempo datasource")
	}
}
