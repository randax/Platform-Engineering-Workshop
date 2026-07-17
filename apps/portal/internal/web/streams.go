package web

// The Streams page: a read-only JetStream browser. Module 09's capstone runs
// on an in-memory broker — restart it and the backlog is gone. JetStream is the
// durable counterpart: streams persist messages to disk, consumers track their
// own position, and nothing is lost across a restart. This page inspects that
// durability from the outside, the same way Buckets inspects object storage —
// no NATS client library, just the monitoring endpoint's JSON (see
// internal/nats). "Durable messaging you can inspect."

import (
	"context"
	"fmt"
	"html/template"
	"log"
	"net/http"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
	"cloudbox.io/portal/internal/nats"
)

func init() {
	register(Page{
		// Weight 68 slots Streams into the Services section after New Function
		// (66). Read-only for now (JetStream CRUD is tracked in PRD-0010).
		Weight:     68,
		NavSection: "Services",
		NavTitle:   "Streams",
		Path:       "/streams",
		Handler:    handleStreams,
		// Messaging: JetStream only answers once the NATS app is deployed and
		// Healthy — before that there is no monitoring endpoint to read, only a
		// connection error. Gate on the same ArgoCD-health signal every other
		// page uses.
		Unlock:     func(s kube.Snapshot) bool { _, h := s.AppHealthy("nats"); return h },
		LockedHint: "Enable NATS · durable messaging",
		Teaser:     "Browse JetStream streams — message counts, bytes on disk, and consumers — the durable messaging backbone you can inspect.",
		Extra: []Route{
			{"GET /streams/list", handleStreamsList}, // polled by htmx
		},
	})
}

// streamsSource is the one slice of NATS this page consumes — a consumer-side
// interface, so the table's rendering is testable with an in-memory fake
// instead of a live monitoring endpoint. *nats.Client satisfies it in
// production (mirrors gallery.go's galleryStore and buckets.go's bucketStore).
type streamsSource interface {
	ListStreams(ctx context.Context) ([]nats.Stream, error)
}

type streamsData struct {
	Streams []nats.Stream
	Flash   flash

	// Monitoring — populated only by the full-page handler (never the 5s-polled
	// fragment, which would re-hit VM), and only when observability collects.
	Telemetry bool
	MsgSpark  template.HTML
	MsgNow    string
	ConnSpark template.HTML
	ConnNow   string
	BytesNow  string
}

// fetchStreams lists the streams and wraps them for the template. Kept separate
// from the HTTP handler so a fake streamsSource can drive it in tests. An empty
// list is not an error — it renders the friendly "JetStream is empty" state.
func fetchStreams(ctx context.Context, src streamsSource, fl flash) (streamsData, error) {
	streams, err := src.ListStreams(ctx)
	if err != nil {
		return streamsData{}, err
	}
	return streamsData{Streams: streams, Flash: fl}, nil
}

func handleStreams(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchStreams(r.Context(), s.Streams, flash{})
	if err != nil {
		s.renderError(w, err)
		return
	}
	// Monitoring: JetStream throughput + server connections from the exporter
	// sidecar, once observability is collecting. Full page only, never the
	// polled fragment.
	if health, err := s.Kube.NamespaceWorkloads(r.Context()); err == nil && health["observability"].Ready > 0 && s.Prom != nil {
		data.Telemetry = true
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.NATSMessagesQuery()); len(v) > 0 {
			data.MsgSpark = metrics.Sparkline(v, "JetStream messages")
			data.MsgNow = fmt.Sprintf("%.0f", v[len(v)-1])
		}
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.NATSConnectionsQuery()); len(v) > 0 {
			data.ConnSpark = metrics.Sparkline(v, "connections")
			data.ConnNow = fmt.Sprintf("%.0f", v[len(v)-1])
		}
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.NATSBytesQuery()); len(v) > 0 {
			data.BytesNow = humanBytes(v[len(v)-1])
		}
	}
	s.render(w, "streams", data)
}

// handleStreamsList serves the 5s-polled table fragment. Like the databases and
// gallery fragments, a read error becomes a flash inside the fragment rather
// than a full error page — that keeps the polling attributes in the DOM, so the
// table heals itself the moment NATS answers again.
func handleStreamsList(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchStreams(r.Context(), s.Streams, flash{})
	if err != nil {
		log.Printf("poll error: %v", err)
		s.render(w, "streams-list", streamsData{Flash: errorFlash("NATS error: " + err.Error())})
		return
	}
	s.render(w, "streams-list", data)
}
