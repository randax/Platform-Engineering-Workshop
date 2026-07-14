package web

// The Activity page is CloudTrail-lite: the cluster already keeps an
// activity log — Kubernetes Events — so "what just happened on my platform"
// is one GET on /api/v1/events, filtered to our namespaces. No audit
// pipeline, no log shipper; the API server had the data all along.

import (
	"context"
	"net/http"

	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		Weight:     40,
		NavSection: "Platform",
		NavTitle:   "Activity",
		Path:       "/activity",
		Handler:    handleActivity,
		Extra: []Route{
			{"GET /activity/list", handleActivityList}, // polled by htmx
		},
	})
}

// platformNamespaces is derived from the component catalog — the same "one
// namespace per component" convention the Components page leans on.
func platformNamespaces() map[string]bool {
	ns := make(map[string]bool, len(componentCatalog))
	for _, c := range componentCatalog {
		ns[c.Namespace] = true
	}
	return ns
}

// recentActivity: one cluster-wide list, filtered client-side to the
// platform's namespaces and capped for the page.
func recentActivity(ctx context.Context, s *Server) ([]kube.Event, error) {
	all, err := s.Kube.ListEvents(ctx, "/api/v1/events", "")
	if err != nil {
		return nil, err
	}
	ours := platformNamespaces()
	events := make([]kube.Event, 0, 50)
	for _, e := range all {
		if !ours[e.Metadata.Namespace] {
			continue
		}
		events = append(events, e)
		if len(events) == 50 {
			break
		}
	}
	return events, nil
}

type activityData struct {
	Events []kube.Event
	Flash  flash
}

func handleActivity(s *Server, w http.ResponseWriter, r *http.Request) {
	events, err := recentActivity(r.Context(), s)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "activity", activityData{Events: events})
}

// handleActivityList: the 10s-polled fragment, self-healing like the others.
func handleActivityList(s *Server, w http.ResponseWriter, r *http.Request) {
	events, err := recentActivity(r.Context(), s)
	if err != nil {
		s.render(w, "activity-list", activityData{Flash: errorFlash("API error: " + err.Error())})
		return
	}
	s.render(w, "activity-list", activityData{Events: events})
}
