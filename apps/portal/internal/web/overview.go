package web

// The Overview page: ArgoCD Applications with health/sync, read straight
// from the Kubernetes API — no client-go, no ArgoCD API server.

import "net/http"

func init() {
	register(Page{
		Weight:     10,
		NavSection: "Platform",
		NavTitle:   "Overview",
		Path:       "/",
		Handler:    handleOverview,
	})
}

func handleOverview(s *Server, w http.ResponseWriter, r *http.Request) {
	apps, err := s.Kube.ListArgoApps(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	sum, _ := s.Kube.Summarize(r.Context()) // best-effort; zeroes render fine
	s.render(w, "overview", map[string]any{"Apps": apps, "Summary": sum})
}
