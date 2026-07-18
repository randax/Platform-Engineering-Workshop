package web

import (
	"bytes"
	"strings"
	"testing"

	"cloudbox.io/portal/internal/kube"
)

// The Functions page now owns the whole lifecycle: list, build-and-deploy,
// invoke, delete. Assert the merged markup renders — the build form, the
// per-row invoke button, and Delete gated to demo-namespace functions.
func TestFunctionsPageRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://localhost:30030"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	data := functionsData{
		Rows: []serviceRow{
			{KnativeService: kube.KnativeService{Metadata: kube.ObjMeta{Name: "fn-hello", Namespace: "demo"}}, Deletable: true},
			{KnativeService: kube.KnativeService{Metadata: kube.ObjMeta{Name: "uploader", Namespace: "pipeline"}}},
		},
		Samples: fnSamples,
	}
	var page bytes.Buffer
	if err := tmpl.ExecuteTemplate(&page, "services", data); err != nil {
		t.Fatalf("render page: %v", err)
	}
	h := page.String()
	for _, want := range []string{
		"Functions",                                               // heading
		`hx-post="/services"`, "hello-site", "Build &amp; deploy", // the build form
		`/services/demo/fn-hello/invoke`,      // invoke any listed function
		`hx-delete="/services/demo/fn-hello"`, // delete targets the function's own namespace
	} {
		if !strings.Contains(h, want) {
			t.Errorf("functions page missing %q", want)
		}
	}
	// Delete must NOT be offered for the capstone ksvc in `pipeline` — the
	// console has no RBAC to remove it, so the button would only 403.
	if strings.Contains(h, `hx-delete="/services/pipeline/uploader"`) {
		t.Error("delete must not be offered for non-demo (capstone) functions")
	}

	// The invoke "Test" panel renders the status + body for a successful call…
	var ok bytes.Buffer
	if err := tmpl.ExecuteTemplate(&ok, "invoke-result", invokeResult{Name: "fn-hello", Status: "200 OK", Class: "ok", Duration: "1.2s", Body: "hello from busybox"}); err != nil {
		t.Fatalf("render invoke-result: %v", err)
	}
	for _, want := range []string{"200 OK", "hello from busybox", "1.2s"} {
		if !strings.Contains(ok.String(), want) {
			t.Errorf("invoke-result missing %q: %s", want, ok.String())
		}
	}
	// …and surfaces an error (e.g. a cold-start timeout) as a flash.
	var bad bytes.Buffer
	if err := tmpl.ExecuteTemplate(&bad, "invoke-result", invokeResult{Name: "fn-hello", Error: "Request failed: timeout"}); err != nil {
		t.Fatalf("render invoke-result err: %v", err)
	}
	if !strings.Contains(bad.String(), "flash-error") {
		t.Errorf("invoke-result error missing flash-error: %s", bad.String())
	}
}

// functionClusterURL must produce the in-cluster address Knative routes through
// the local gateway (so scale-from-zero works) — never a browser/ingress URL.
func TestFunctionClusterURL(t *testing.T) {
	if got := functionClusterURL("demo", "fn-hello"); got != "http://fn-hello.demo.svc.cluster.local" {
		t.Errorf("cluster URL = %q", got)
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
