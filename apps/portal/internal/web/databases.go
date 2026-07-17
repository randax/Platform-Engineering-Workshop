package web

// The Databases page: CNPG clusters + the WorkshopDatabase self-service API
// from module 04. The form POSTs a ~10-line XR; Crossplane composes the
// actual database and bucket.

import (
	"context"
	"net/http"

	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		Weight:     56,
		NavSection: "Services",
		NavTitle:   "Databases",
		Path:       "/databases",
		Handler:    handleDatabases,
		// Self-service (module 04): the WorkshopDatabase XR and its form only
		// mean anything once Crossplane is installed and Healthy to compose it.
		Unlock:     func(s kube.Snapshot) bool { _, h := s.AppHealthy("crossplane"); return h },
		LockedHint: "Complete Module 04 · Self-service",
		Teaser:     "Provision a Postgres database and its bucket from one small form — Crossplane composes the real resources for you.",
		// Mutating routes. No CSRF token on these: single-user disposable
		// lab — don't copy this into a real portal.
		Extra: []Route{
			{"GET /databases/list", handleDatabasesList}, // polled by htmx
			{"GET /databases/{name}", handleDatabaseDetail},
			{"POST /databases", handleCreateDatabase},
			{"DELETE /databases/{name}", handleDeleteDatabase},
		},
	})
}

type databasesData struct {
	Clusters  []kube.CNPGCluster
	Databases []kube.WorkshopDB
	Namespace string
	Flash     flash
}

func fetchDatabases(ctx context.Context, s *Server, fl flash) (databasesData, error) {
	clusters, err := s.Kube.ListCNPGClusters(ctx)
	if err != nil {
		return databasesData{}, err
	}
	dbs, err := s.Kube.ListWorkshopDatabases(ctx)
	if err != nil {
		return databasesData{}, err
	}
	return databasesData{Clusters: clusters, Databases: dbs, Namespace: kube.XRNamespace, Flash: fl}, nil
}

func handleDatabases(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchDatabases(r.Context(), s, flash{})
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "databases", data)
}

// handleDatabasesList serves the self-refreshing tables fragment that htmx
// polls every 5 seconds. On error it renders the fragment with an error
// flash instead of a full error page — that keeps the polling attributes in
// the DOM, so the tables heal themselves once the API answers again.
func handleDatabasesList(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchDatabases(r.Context(), s, flash{})
	if err != nil {
		data = databasesData{Namespace: kube.XRNamespace, Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "db-list", data)
}

// handleCreateDatabase is the "platform API in one POST" moment: the form
// fields become a WorkshopDatabase XR, and Crossplane does the rest. The
// response is the refreshed list fragment, which htmx swaps in place.
func handleCreateDatabase(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	size := r.FormValue("size")

	fl := flash{Msg: "Created " + name + " — Crossplane is composing a Postgres cluster and a bucket. Watch it turn Ready below."}
	if err := s.Kube.CreateWorkshopDatabase(r.Context(), name, size); err != nil {
		fl = errorFlash("Create failed: " + err.Error())
	}
	// Always answer with the fragment htmx targeted — a full 500 error page
	// would not be swapped in and the button would appear to do nothing.
	data, err := fetchDatabases(r.Context(), s, fl)
	if err != nil {
		data = databasesData{Namespace: kube.XRNamespace, Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "db-list", data)
}

// handleDeleteDatabase is wired to the detail page (real-console
// convention: destructive actions live next to full context, not on list
// rows). On success an HX-Redirect header sends the browser back to the
// list; on failure the error lands in the detail page's #delete-result slot.
func handleDeleteDatabase(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if err := s.Kube.DeleteWorkshopDatabase(r.Context(), name); err != nil {
		s.render(w, "flash", errorFlash("Delete failed: "+err.Error()))
		return
	}
	w.Header().Set("HX-Redirect", "/databases")
}
