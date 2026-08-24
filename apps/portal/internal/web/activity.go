package web

import (
	"context"
	"net/http"
	"sort"

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
			{"GET /activity/list", handleActivityList},
		},
	})
}

func platformNamespaces() map[string]bool {
	ns := make(map[string]bool, len(componentCatalog))
	for _, c := range componentCatalog {
		ns[c.Namespace] = true
	}
	return ns
}

func recentActivity(ctx context.Context, s *Server, filterNS, filterType string) ([]kube.Event, error) {
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
		if filterNS != "" && e.Metadata.Namespace != filterNS {
			continue
		}
		if filterType != "" && e.Type != filterType {
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
	Events     []kube.Event
	Namespaces []string
	FilterNS   string
	FilterType string
	Flash      flash
}

func getActivityData(ctx context.Context, s *Server, r *http.Request) (activityData, error) {
	fns := r.URL.Query().Get("ns")
	ftype := r.URL.Query().Get("type")
	events, err := recentActivity(ctx, s, fns, ftype)
	if err != nil {
		return activityData{}, err
	}
	var nss []string
	ours := platformNamespaces()
	for n := range ours {
		nss = append(nss, n)
	}
	sort.Strings(nss)
	return activityData{
		Events:     events,
		Namespaces: nss,
		FilterNS:   fns,
		FilterType: ftype,
	}, nil
}

func handleActivity(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := getActivityData(r.Context(), s, r)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "activity", data)
}

func handleActivityList(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := getActivityData(r.Context(), s, r)
	if err != nil {
		s.render(w, "activity-list", activityData{Flash: errorFlash("API error: " + err.Error())})
		return
	}
	s.render(w, "activity-list", data)
}
