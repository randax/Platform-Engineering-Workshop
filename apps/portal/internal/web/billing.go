package web

// The Billing page — the sovereignty punchline, rendered with a straight
// face. The usage numbers are real (internal/kube computes requests vs
// allocatable from the API server); the prices are the point.

import (
	"net/http"
	"time"

	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		Weight:     50,
		NavSection: "Platform",
		NavTitle:   "Billing",
		Path:       "/billing",
		Handler:    handleBilling,
	})
}

type billingData struct {
	Month   string
	Nodes   []kube.NodeUsage
	DBCount int
}

func handleBilling(s *Server, w http.ResponseWriter, r *http.Request) {
	nodes, err := s.Kube.NodeUsages(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	dbCount := 0
	if dbs, err := s.Kube.ListWorkshopDatabases(r.Context()); err == nil {
		dbCount = len(dbs)
	}
	s.render(w, "billing", billingData{
		Month:   time.Now().Format("January 2006"),
		Nodes:   nodes,
		DBCount: dbCount,
	})
}
