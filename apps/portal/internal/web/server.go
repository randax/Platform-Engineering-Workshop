package web

// Server carries the console's dependencies into the page handlers, plus
// the shared render helpers every page uses.

import (
	"context"
	"html/template"
	"log"
	"net/http"
	"sync"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
	"cloudbox.io/portal/internal/store"
)

type Server struct {
	Kube        *kube.Client
	Store       *store.Client
	Prom        *metrics.Client
	Tmpl        *template.Template
	UploaderURL string              // cluster-internal URL of the uploader Knative Service
	GrafanaURL  string              // browser-facing Grafana base for deep links
	HTTPClient  *http.Client        // traced client for forwarding uploads
	Pages       metric.Int64Counter // OTLP: cloudbox.pages.rendered → prom cloudbox_pages_rendered_total

	// Unlock-state cache. The sidebar is rebuilt on every request (see the
	// nav closure in ParseTemplates), and every gated handler re-checks its
	// predicate per request, so the snapshot behind those checks is cached
	// rather than re-read from the API server each time.
	snapMu sync.Mutex
	snap   kube.Snapshot
	snapAt time.Time
}

// snapshotTTL bounds how often currentSnapshot re-reads the cluster. A few
// seconds is imperceptible to someone working through a module, but turns a
// burst of nav renders + handler checks into a single API round-trip.
const snapshotTTL = 5 * time.Second

// currentSnapshot returns a recent cluster snapshot for unlock decisions,
// refreshing it at most once per snapshotTTL. It runs inline on the request
// path (the nav needs it to decide which pages are locked), so the refresh
// uses a short timeout and never blocks the page on a slow API server.
//
// On a read error the last-known snapshot is kept and returned — a transient
// API blip must not relock a page the user has already unlocked, and it must
// not turn the sidebar into an error page. The very first failure returns the
// zero snapshot, which reads as "nothing unlocked yet", the honest default.
func (s *Server) currentSnapshot() kube.Snapshot {
	s.snapMu.Lock()
	defer s.snapMu.Unlock()

	// A Server with no Kube client (the template unit tests build a bare one)
	// has nothing to read: hand back the zero snapshot so the nav still
	// renders, with every gated page simply reading as locked.
	if s.Kube == nil {
		return s.snap
	}
	if !s.snapAt.IsZero() && time.Since(s.snapAt) < snapshotTTL {
		return s.snap
	}

	// Stamp the attempt time before the read so a persistently failing API
	// server is retried at most once per TTL, not on every single request.
	s.snapAt = time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if snap, err := workshopSnapshot(ctx, s); err == nil {
		s.snap = snap
	}
	return s.snap
}

// flash is a one-shot notice rendered at the top of a fragment. Error flips
// the styling from info-blue to error-red so failures stand out on sight.
type flash struct {
	Msg   string
	Error bool
}

func errorFlash(msg string) flash { return flash{Msg: msg, Error: true} }

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	if s.Pages != nil {
		s.Pages.Add(context.Background(), 1, metric.WithAttributes(attribute.String("page", name)))
	}
	if err := s.Tmpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

// renderError shows the error inside the page instead of a bare 500 — during
// the workshop, "what did the API say" *is* the content.
func (s *Server) renderError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	w.WriteHeader(http.StatusInternalServerError)
	s.render(w, "error", err.Error())
}
