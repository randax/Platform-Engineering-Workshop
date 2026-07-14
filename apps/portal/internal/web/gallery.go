package web

// The Gallery page: the capstone pipeline seen from the outside. Uploads
// are proxied to the uploader Knative Service (the browser can't reach its
// cluster-internal URL); the grid joins originals with the resizer's output.

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"

	"cloudbox.io/portal/internal/store"
)

func init() {
	register(Page{
		Weight:     80,
		NavSection: "Capstone",
		NavTitle:   "Gallery",
		Path:       "/gallery",
		Handler:    handleGallery,
		// POST is CSRF-token-free on purpose — see the databases page note.
		Extra: []Route{
			{"GET /gallery/grid", handleGalleryGrid}, // polled by htmx
			{"POST /gallery/upload", handleUpload},
		},
	})
}

// galleryStore is the one slice of object storage the gallery consumes — a
// consumer-side interface, so grid logic is testable with an in-memory fake
// instead of a real S3.
type galleryStore interface {
	ListGallery(ctx context.Context) ([]store.Item, error)
}

type galleryData struct {
	Items []store.Item
	Flash flash
}

func galleryItems(ctx context.Context, st galleryStore, fl flash) (galleryData, error) {
	items, err := st.ListGallery(ctx)
	if err != nil {
		return galleryData{}, err
	}
	return galleryData{Items: items, Flash: fl}, nil
}

func handleGallery(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := galleryItems(r.Context(), s.Store, flash{})
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "gallery", data)
}

// handleGalleryGrid serves the polled grid fragment; like the databases
// list, errors become a flash inside the fragment so polling keeps running.
func handleGalleryGrid(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := galleryItems(r.Context(), s.Store, flash{})
	if err != nil {
		log.Printf("poll error: %v", err)
		s.render(w, "gallery-grid", galleryData{Flash: errorFlash("S3 error: " + err.Error())})
		return
	}
	s.render(w, "gallery-grid", data)
}

// maxUploadBytes caps proxied uploads at 25 MB (the uploader enforces the
// same limit — this just fails fast without shipping the bytes anywhere).
const maxUploadBytes = 25 << 20

// handleUpload forwards the browser's multipart POST to the uploader Knative
// Service. The browser can't reach the uploader itself — its URL only
// resolves inside the cluster — so the portal replays the request body
// verbatim (a three-line reverse proxy).
func handleUpload(s *Server, w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, s.UploaderURL+"/upload", r.Body)
	if err != nil {
		s.renderError(w, err)
		return
	}
	// Preserve Content-Length; otherwise Go falls back to chunked encoding,
	// which some ingress/Knative paths reject or can't size-validate.
	req.ContentLength = r.ContentLength
	req.Header.Set("Content-Type", r.Header.Get("Content-Type")) // multipart boundary lives here

	fl := flash{Msg: "Uploaded — the resizer is waking from zero; the thumbnail and analysis will appear below."}
	resp, err := s.HTTPClient.Do(req)
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
	data, err := galleryItems(r.Context(), s.Store, fl)
	if err != nil {
		s.render(w, "gallery-grid", galleryData{Flash: errorFlash("S3 error: " + err.Error())})
		return
	}
	s.render(w, "gallery-grid", data)
}
