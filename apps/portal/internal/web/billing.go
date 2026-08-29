package web

// The Billing page — the sovereignty punchline, rendered with a straight
// face. The usage numbers are real (internal/kube computes requests vs
// allocatable from the API server); the prices are the point.

import (
	"log"
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
	// Namespace-scoped, and for the same reason workshop.go says so at length:
	// the portal's only WorkshopDatabase grant is a Role in ns demo
	// (lab/08-portal/portal-access.yaml), so a cluster-wide list 403s. The error
	// was swallowed here, which billed an attendee with two Ready databases for
	// "0 provisioned" — live node figures beside a dead number on the same page.
	// A miss is now visible rather than quietly zero.
	dbCount := 0
	if dbs, err := s.Kube.ListWorkshopDatabases(r.Context(), "demo"); err == nil {
		dbCount = len(dbs)
	} else {
		log.Printf("billing: counting WorkshopDatabases in demo: %v", err)
	}
	s.render(w, "billing", billingData{
		Month:   time.Now().Format("January 2006"),
		Nodes:   nodes,
		DBCount: dbCount,
	})
}
