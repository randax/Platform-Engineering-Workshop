package web

// Server carries the console's dependencies into the page handlers, plus
// the shared render helpers every page uses.

import (
	"context"
	"html/template"
	"log"
	"net/http"

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
