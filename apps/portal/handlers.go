package main

// HTTP handlers — one per page, plus the htmx fragment endpoints. The pattern
// throughout: forms and buttons carry hx-* attributes, the server answers
// with a rendered HTML fragment, htmx swaps it into the page. No JSON API, no
// frontend build step. The db-list and gallery fragments also poll themselves
// every 5 seconds (see the hx-trigger comments in the templates), which is
// all it takes to make the console feel live.

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
)

// flash is a one-shot notice rendered at the top of a fragment. Error flips
// the styling from info-blue to error-red so failures stand out on sight.
type flash struct {
	Msg   string
	Error bool
}

func errorFlash(msg string) flash { return flash{Msg: msg, Error: true} }

func (s *server) render(w http.ResponseWriter, name string, data any) {
	if err := s.tmpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

// renderError shows the error inside the page instead of a bare 500 — during
// the workshop, "what did the API say" *is* the content.
func (s *server) renderError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	w.WriteHeader(http.StatusInternalServerError)
	s.render(w, "error", err.Error())
}

// ---------------------------------------------------------------- overview

func (s *server) handleOverview(w http.ResponseWriter, r *http.Request) {
	apps, err := s.kube.listArgoApps(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	sum, _ := s.kube.summarize(r.Context()) // best-effort; zeroes render fine
	s.render(w, "overview", map[string]any{"Apps": apps, "Summary": sum})
}

// --------------------------------------------------------------- databases

type databasesData struct {
	Clusters  []cnpgCluster
	Databases []workshopDB
	Namespace string
	Flash     flash
}

func (s *server) databasesData(ctx context.Context, fl flash) (databasesData, error) {
	clusters, err := s.kube.listCNPGClusters(ctx)
	if err != nil {
		return databasesData{}, err
	}
	dbs, err := s.kube.listWorkshopDatabases(ctx)
	if err != nil {
		return databasesData{}, err
	}
	return databasesData{Clusters: clusters, Databases: dbs, Namespace: xrNamespace, Flash: fl}, nil
}

func (s *server) handleDatabases(w http.ResponseWriter, r *http.Request) {
	data, err := s.databasesData(r.Context(), flash{})
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
func (s *server) handleDatabasesList(w http.ResponseWriter, r *http.Request) {
	data, err := s.databasesData(r.Context(), flash{})
	if err != nil {
		log.Printf("poll error: %v", err)
		data = databasesData{Namespace: xrNamespace, Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "db-list", data)
}

// handleCreateDatabase is the "platform API in one POST" moment: the form
// fields become a WorkshopDatabase XR, and Crossplane does the rest. The
// response is the refreshed list fragment, which htmx swaps in place.
func (s *server) handleCreateDatabase(w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	size := r.FormValue("size")
	storageGB, _ := strconv.Atoi(r.FormValue("storageGB"))

	fl := flash{Msg: "Created " + name + " — Crossplane is composing a Postgres cluster and a bucket. Watch it turn Ready below."}
	if err := s.kube.createWorkshopDatabase(r.Context(), name, size, storageGB); err != nil {
		fl = errorFlash("Create failed: " + err.Error())
	}
	// Always answer with the fragment htmx targeted — a full 500 error page
	// would not be swapped in and the button would appear to do nothing.
	data, err := s.databasesData(r.Context(), fl)
	if err != nil {
		data = databasesData{Namespace: xrNamespace, Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "db-list", data)
}

func (s *server) handleDeleteDatabase(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	fl := flash{Msg: "Deleted " + name + " (composed resources are garbage-collected with it)."}
	if err := s.kube.deleteWorkshopDatabase(r.Context(), name); err != nil {
		fl = errorFlash("Delete failed: " + err.Error())
	}
	// Fragment even on failure — see handleCreateDatabase.
	data, err := s.databasesData(r.Context(), fl)
	if err != nil {
		data = databasesData{Namespace: xrNamespace, Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "db-list", data)
}

// ----------------------------------------------------------------- gallery

type galleryData struct {
	Items []galleryItem
	Flash flash
}

func (s *server) handleGallery(w http.ResponseWriter, r *http.Request) {
	items, err := s.s3.listGallery(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "gallery", galleryData{Items: items})
}

// handleGalleryGrid serves the polled grid fragment; like the databases
// list, errors become a flash inside the fragment so polling keeps running.
func (s *server) handleGalleryGrid(w http.ResponseWriter, r *http.Request) {
	items, err := s.s3.listGallery(r.Context())
	if err != nil {
		log.Printf("poll error: %v", err)
		s.render(w, "gallery-grid", galleryData{Flash: errorFlash("S3 error: " + err.Error())})
		return
	}
	s.render(w, "gallery-grid", galleryData{Items: items})
}

// maxUploadBytes caps proxied uploads at 25 MB (the uploader enforces the
// same limit — this just fails fast without shipping the bytes anywhere).
const maxUploadBytes = 25 << 20

// handleUpload forwards the browser's multipart POST to the uploader Knative
// Service. The browser can't reach the uploader itself — its URL only
// resolves inside the cluster — so the portal replays the request body
// verbatim (a three-line reverse proxy).
func (s *server) handleUpload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, s.uploaderURL+"/upload", r.Body)
	if err != nil {
		s.renderError(w, err)
		return
	}
	req.Header.Set("Content-Type", r.Header.Get("Content-Type")) // multipart boundary lives here

	fl := flash{Msg: "Uploaded — the resizer is waking from zero; the thumbnail and analysis will appear below."}
	resp, err := s.httpClient.Do(req)
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		fl = errorFlash("Upload too large — max 25 MB.")
	case err != nil:
		fl = errorFlash("Upload failed: " + err.Error() + " (is the uploader Knative Service running?)")
	default:
		defer resp.Body.Close()
		reply, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		log.Printf("uploader replied %s: %s", resp.Status, reply)
		if resp.StatusCode >= 300 {
			fl = errorFlash("Uploader said " + resp.Status + ": " + string(reply))
		}
	}

	// Fragment even on failure — see handleCreateDatabase.
	items, err := s.s3.listGallery(r.Context())
	if err != nil {
		s.render(w, "gallery-grid", galleryData{Flash: errorFlash("S3 error: " + err.Error())})
		return
	}
	s.render(w, "gallery-grid", galleryData{Items: items, Flash: fl})
}

// ---------------------------------------------------------------- services

func (s *server) handleServices(w http.ResponseWriter, r *http.Request) {
	svcs, err := s.kube.listKnativeServices(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "services", svcs)
}
