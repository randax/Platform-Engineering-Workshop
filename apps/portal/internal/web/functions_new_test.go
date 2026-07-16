package web

import (
	"bytes"
	"strings"
	"testing"
)

func TestFunctionsNewRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://localhost:30030"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	// The form page lists the vetted samples and points its POST at /functions.
	var page bytes.Buffer
	if err := tmpl.ExecuteTemplate(&page, "functions-new", functionsNewData{Samples: fnSamples}); err != nil {
		t.Fatalf("render page: %v", err)
	}
	h := page.String()
	for _, want := range []string{"New Function", `hx-post="/functions"`, "hello-site", "Build &amp; deploy"} {
		if !strings.Contains(h, want) {
			t.Errorf("functions-new page missing %q", want)
		}
	}

	// The result fragment carries just the flash (success guidance or error).
	var res bytes.Buffer
	if err := tmpl.ExecuteTemplate(&res, "fn-result", functionsNewData{Flash: flash{Msg: "Building fn-x"}}); err != nil {
		t.Fatalf("render result: %v", err)
	}
	if !strings.Contains(res.String(), "Building fn-x") {
		t.Errorf("fn-result missing the flash message: %s", res.String())
	}
}

func TestLookupSample(t *testing.T) {
	if _, ok := lookupSample("hello-site"); !ok {
		t.Error("expected the hello-site sample to be vetted")
	}
	// A crafted key must not resolve — the browser only ever submits a key, so
	// an unknown one is the whole defence against pointing a build anywhere.
	if _, ok := lookupSample("https://github.com/evil/repo.git"); ok {
		t.Error("an off-whitelist source must not resolve")
	}
}
