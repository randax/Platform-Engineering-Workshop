package main

// HTTP handlers — one per page, plus the htmx fragment endpoints. The pattern
// throughout: forms and buttons carry hx-* attributes, the server answers
// with a rendered HTML fragment, htmx swaps it into the page. No JSON API, no
// frontend build step.

import (
	"context"
	"io"
	"log"
	"net/http"
	"strconv"
)

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
	Flash     string
}

func (s *server) databasesData(ctx context.Context, flash string) (databasesData, error) {
	clusters, err := s.kube.listCNPGClusters(ctx)
	if err != nil {
		return databasesData{}, err
	}
	dbs, err := s.kube.listWorkshopDatabases(ctx)
	if err != nil {
		return databasesData{}, err
	}
	return databasesData{Clusters: clusters, Databases: dbs, Namespace: xrNamespace, Flash: flash}, nil
}

func (s *server) handleDatabases(w http.ResponseWriter, r *http.Request) {
	data, err := s.databasesData(r.Context(), "")
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "databases", data)
}

// handleCreateDatabase is the "platform API in one POST" moment: the form
// fields become a WorkshopDatabase XR, and Crossplane does the rest. The
// response is the refreshed list fragment, which htmx swaps in place.
func (s *server) handleCreateDatabase(w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	size := r.FormValue("size")
	storageGB, _ := strconv.Atoi(r.FormValue("storageGB"))

	flash := "Created " + name + " — Crossplane is composing a Postgres cluster and a bucket. Refresh to watch it turn Ready."
	if err := s.kube.createWorkshopDatabase(r.Context(), name, size, storageGB); err != nil {
		flash = "Create failed: " + err.Error()
	}
	data, err := s.databasesData(r.Context(), flash)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "db-list", data)
}

func (s *server) handleDeleteDatabase(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	flash := "Deleted " + name + " (composed resources are garbage-collected with it)."
	if err := s.kube.deleteWorkshopDatabase(r.Context(), name); err != nil {
		flash = "Delete failed: " + err.Error()
	}
	data, err := s.databasesData(r.Context(), flash)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "db-list", data)
}

// ----------------------------------------------------------------- gallery

type galleryData struct {
	Items []galleryItem
	Flash string
}

func (s *server) handleGallery(w http.ResponseWriter, r *http.Request) {
	items, err := s.s3.listGallery(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "gallery", galleryData{Items: items})
}

func (s *server) handleGalleryGrid(w http.ResponseWriter, r *http.Request) {
	items, err := s.s3.listGallery(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "gallery-grid", galleryData{Items: items})
}

// handleUpload forwards the browser's multipart POST to the uploader Knative
// Service. The browser can't reach the uploader itself — its URL only
// resolves inside the cluster — so the portal replays the request body
// verbatim (a three-line reverse proxy).
func (s *server) handleUpload(w http.ResponseWriter, r *http.Request) {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, s.uploaderURL+"/upload", r.Body)
	if err != nil {
		s.renderError(w, err)
		return
	}
	req.Header.Set("Content-Type", r.Header.Get("Content-Type")) // multipart boundary lives here

	flash := "Uploaded. The resizer wakes from zero to process it — refresh in a few seconds to see the thumbnail."
	resp, err := s.httpClient.Do(req)
	if err != nil {
		flash = "Upload failed: " + err.Error() + " (is the uploader Knative Service running?)"
	} else {
		defer resp.Body.Close()
		reply, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		log.Printf("uploader replied %s: %s", resp.Status, reply)
		if resp.StatusCode >= 300 {
			flash = "Uploader said " + resp.Status + ": " + string(reply)
		}
	}

	items, err := s.s3.listGallery(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "gallery-grid", galleryData{Items: items, Flash: flash})
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
