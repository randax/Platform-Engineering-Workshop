package main

import "testing"

func fixtureApp(name, health string) argoApp {
	a := argoApp{}
	a.Metadata.Name = name
	a.Status.Health.Status = health
	return a
}

// A mid-workshop cluster: modules 01/02/06/08 complete, 03 half-way,
// 04/07/09 untouched. The rules must map that state onto the checklist.
func TestEvaluateModules(t *testing.T) {
	snap := snapshot{
		apps: map[string]argoApp{
			"platform":        fixtureApp("platform", "Healthy"),
			"cnpg-operator":   fixtureApp("cnpg-operator", "Healthy"),
			"knative-serving": fixtureApp("knative-serving", "Healthy"),
			"portal":          fixtureApp("portal", "Healthy"),
			// note: rustfs exists but is NOT Healthy → does not count
			"rustfs": fixtureApp("rustfs", "Progressing"),
		},
		nodesTotal:    2,
		nodesReady:    2,
		kubeProxyPods: 0, // Cilium replaced kube-proxy
		giteaHealthy:  true,
		ksvcReady:     true,
	}

	want := map[string]string{
		"00": "Done",
		"01": "Done",
		"02": "Done",
		"03": "In progress", // cnpg-operator yes, rustfs unhealthy, no demo cluster
		"04": "Not started",
		"05": "Manual check", // never inferred
		"06": "Done",
		"07": "Not started",
		"08": "Done",
		"09": "Not started",
	}

	rows := evaluateModules(snap)
	if len(rows) != 10 {
		t.Fatalf("expected 10 modules, got %d", len(rows))
	}
	for _, r := range rows {
		if r.Status != want[r.Number] {
			t.Errorf("module %s (%s): status %q, want %q", r.Number, r.Title, r.Status, want[r.Number])
		}
		// Done rows hide the next step; everything else should point somewhere.
		if r.Status == "Done" && r.Next != "" {
			t.Errorf("module %s: done but still shows next step %q", r.Number, r.Next)
		}
		if r.Status != "Done" && r.Next == "" {
			t.Errorf("module %s: not done but has no next step", r.Number)
		}
	}
}

// Fresh cluster with kube-proxy still running: module 01 is only half-true.
func TestEvaluateModulesKubeProxyStillThere(t *testing.T) {
	snap := snapshot{apps: map[string]argoApp{}, nodesTotal: 2, nodesReady: 2, kubeProxyPods: 2}
	for _, r := range evaluateModules(snap) {
		if r.Number == "01" && r.Status != "In progress" {
			t.Errorf("module 01 with kube-proxy present: %q, want In progress", r.Status)
		}
	}
}
