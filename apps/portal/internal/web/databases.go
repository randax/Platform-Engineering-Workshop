package web

// The Databases page: CNPG clusters + the WorkshopDatabase self-service API
// from module 04. The form POSTs a ~10-line XR; Crossplane composes the
// actual database and bucket.

import (
	"context"
	"fmt"
	"html/template"
	"net/http"
	"database/sql"
	_ "github.com/lib/pq"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
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
			{"POST /databases/{name}/query", handleDatabaseQuery},
			{"POST /databases/{name}/resize", handleResizeDatabase},
			{"DELETE /databases/{name}", handleDeleteDatabase},
		},
	})
}

type databasesData struct {
	Clusters  []kube.CNPGCluster
	Databases []kube.WorkshopDB
	Namespace string
	Flash     flash
	Telemetry bool
	CPUSpark  template.HTML
	CPUNow    string
	MemSpark  template.HTML
	MemNow    string
}

func fetchDatabases(ctx context.Context, s *Server, ns string, fl flash) (databasesData, error) {
	clusters, err := s.Kube.ListCNPGClusters(ctx)
	if err != nil {
		return databasesData{}, err
	}
	dbs, err := s.Kube.ListWorkshopDatabases(ctx, ns)
	if err != nil {
		return databasesData{}, err
	}
	
	data := databasesData{Clusters: clusters, Databases: dbs, Namespace: ns, Flash: fl}
	if health, err := s.Kube.NamespaceWorkloads(ctx); err == nil && health["observability"].Ready > 0 && s.Prom != nil {
		data.Telemetry = true
		if vals, err := s.Prom.QueryRange(ctx, metrics.NamespaceCPUQuery(ns)); err == nil && len(vals) > 0 {
			data.CPUSpark = metrics.Sparkline(vals, "cpu usage")
			data.CPUNow = fmt.Sprintf("%.2f cores", vals[len(vals)-1])
		}
		if vals, err := s.Prom.QueryRange(ctx, metrics.NamespaceMemQuery(ns)); err == nil && len(vals) > 0 {
			data.MemSpark = metrics.Sparkline(vals, "memory usage")
			data.MemNow = humanBytes(vals[len(vals)-1])
		}
	}
	return data, nil
}

func handleDatabases(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchDatabases(r.Context(), s, s.activeProject(r), flash{})
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
	ns := s.activeProject(r)
	data, err := fetchDatabases(r.Context(), s, ns, flash{})
	if err != nil {
		data = databasesData{Namespace: ns, Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "db-list", data)
}

// handleCreateDatabase is the "platform API in one POST" moment: the form
// fields become a WorkshopDatabase XR, and Crossplane does the rest. The
// response is the refreshed list fragment, which htmx swaps in place.
func handleCreateDatabase(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	size := r.FormValue("size")
	version := r.FormValue("version")
	ns, err := s.mutableProject(r)
	if err != nil {
		s.render(w, "db-list", databasesData{Namespace: kube.XRNamespace, Flash: errorFlash(err.Error())})
		return
	}

	fl := flash{Msg: "Created " + name + " — Crossplane is composing a Postgres cluster and a bucket. Watch it turn Ready below."}
	if err := s.Kube.CreateWorkshopDatabase(r.Context(), ns, name, size, version); err != nil {
		fl = errorFlash("Create failed: " + err.Error())
	}
	// Always answer with the fragment htmx targeted — a full 500 error page
	// would not be swapped in and the button would appear to do nothing.
	data, err := fetchDatabases(r.Context(), s, ns, fl)
	if err != nil {
		data = databasesData{Namespace: ns, Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "db-list", data)
}

// handleDeleteDatabase is wired to the detail page (real-console
// convention: destructive actions live next to full context, not on list
// rows). On success an HX-Redirect header sends the browser back to the
// list; on failure the error lands in the detail page's #delete-result slot.
func handleDeleteDatabase(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	ns, err := s.mutableProject(r)
	if err != nil {
		s.render(w, "flash", errorFlash(err.Error()))
		return
	}
	if err := s.Kube.DeleteWorkshopDatabase(r.Context(), ns, name); err != nil {
		s.render(w, "flash", errorFlash("Delete failed: "+err.Error()))
		return
	}
	w.Header().Set("HX-Redirect", "/databases")
}

// handleResizeDatabase changes the database's T-shirt size (a merge patch on
// spec.size) and reloads the detail page so the new size + re-composing
// conditions show. On failure the error lands in the resize form's result slot,
// keeping the page put — same pattern as delete.
func handleResizeDatabase(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	size := r.FormValue("size")
	version := r.FormValue("version")
	ns, err := s.mutableProject(r)
	if err != nil {
		s.render(w, "flash", errorFlash(err.Error()))
		return
	}
	if err := s.Kube.ResizeWorkshopDatabase(r.Context(), ns, name, size, version); err != nil {
		s.render(w, "flash", errorFlash("Resize failed: "+err.Error()))
		return
	}
	// Reload the detail page: Crossplane is re-composing, and the page's live
	// conditions + size now reflect the new T-shirt.
	w.Header().Set("HX-Redirect", "/databases/"+name)
}

func handleDatabaseQuery(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	query := r.FormValue("query")
	ns := s.activeProject(r)

	if query == "" {
		s.render(w, "query-result", map[string]any{"Error": "Query is empty"})
		return
	}

	cluster, clusterName, err := s.Kube.GetCNPGCluster(r.Context(), ns, name)
	if err != nil || cluster == nil || clusterName == "" {
		s.render(w, "query-result", map[string]any{"Error": "Database not found or not composed yet"})
		return
	}

	sec, err := s.Kube.GetSecret(r.Context(), ns, clusterName+"-app")
	if err != nil {
		s.render(w, "query-result", map[string]any{"Error": "Failed to read credentials: " + err.Error()})
		return
	}

	user := string(sec.Data["user"])
	pass := string(sec.Data["password"])
	dbname := string(sec.Data["dbname"])
	host := clusterName + "-rw." + ns + ".svc.cluster.local"

	connStr := fmt.Sprintf("postgres://%s:%s@%s:5432/%s?sslmode=require", user, pass, host, dbname)
	
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		s.render(w, "query-result", map[string]any{"Error": "Failed to open connection: " + err.Error()})
		return
	}
	defer db.Close()

	rows, err := db.QueryContext(r.Context(), query)
	if err != nil {
		s.render(w, "query-result", map[string]any{"Error": "Query error: " + err.Error()})
		return
	}
	defer rows.Close()

	cols, err := rows.Columns()
	if err != nil {
		s.render(w, "query-result", map[string]any{"Error": "Failed to read columns: " + err.Error()})
		return
	}

	var results [][]string
	for rows.Next() {
		columns := make([]interface{}, len(cols))
		columnPointers := make([]interface{}, len(cols))
		for i := range columns {
			columnPointers[i] = &columns[i]
		}

		if err := rows.Scan(columnPointers...); err != nil {
			continue
		}

		rowStrs := make([]string, len(cols))
		for i, val := range columns {
			if val == nil {
				rowStrs[i] = "NULL"
			} else {
				if b, ok := val.([]byte); ok {
					rowStrs[i] = string(b)
				} else {
					rowStrs[i] = fmt.Sprintf("%v", val)
				}
			}
		}
		results = append(results, rowStrs)
	}

	s.render(w, "query-result", map[string]any{
		"Columns": cols,
		"Rows":    results,
	})
}
