package main

// The Activity page is CloudTrail-lite: the cluster already keeps an
// activity log — Kubernetes Events — so "what just happened on my platform"
// is one GET on /api/v1/events, filtered to our namespaces. No audit
// pipeline, no log shipper; the API server had the data all along.

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"time"
)

// k8sEvent is the slice of a core/v1 Event the pages show.
type k8sEvent struct {
	Metadata       objMeta `json:"metadata"`
	Type           string  `json:"type"` // Normal | Warning
	Reason         string  `json:"reason"`
	Message        string  `json:"message"`
	Count          int     `json:"count"`
	LastTimestamp  string  `json:"lastTimestamp"`
	EventTime      string  `json:"eventTime"`
	InvolvedObject struct {
		Kind      string `json:"kind"`
		Name      string `json:"name"`
		Namespace string `json:"namespace"`
	} `json:"involvedObject"`
}

// when picks the freshest timestamp an Event carries (the API populates
// different fields depending on who reported it).
func (e k8sEvent) when() time.Time {
	for _, s := range []string{e.LastTimestamp, e.EventTime, e.Metadata.CreationTimestamp} {
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			return t
		}
	}
	return time.Time{}
}

// Age renders "how long ago" the way consoles do.
func (e k8sEvent) Age() string {
	t := e.when()
	if t.IsZero() {
		return "?"
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	default:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
}

// listEvents fetches events from one API path (cluster-wide or namespaced,
// optionally with a fieldSelector), newest first.
func (k *kubeClient) listEvents(ctx context.Context, path, fieldSelector string) ([]k8sEvent, error) {
	if fieldSelector != "" {
		path += "?fieldSelector=" + url.QueryEscape(fieldSelector)
	}
	var list struct {
		Items []k8sEvent `json:"items"`
	}
	if err := k.get(ctx, path, &list); err != nil {
		return nil, err
	}
	sort.Slice(list.Items, func(i, j int) bool { return list.Items[i].when().After(list.Items[j].when()) })
	return list.Items, nil
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
func (s *server) recentActivity(ctx context.Context) ([]k8sEvent, error) {
	all, err := s.kube.listEvents(ctx, "/api/v1/events", "")
	if err != nil {
		return nil, err
	}
	ours := platformNamespaces()
	events := make([]k8sEvent, 0, 50)
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

// ---------------------------------------------------------------- handlers

type activityData struct {
	Events []k8sEvent
	Flash  flash
}

func (s *server) handleActivity(w http.ResponseWriter, r *http.Request) {
	events, err := s.recentActivity(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "activity", activityData{Events: events})
}

// handleActivityList: the 10s-polled fragment, self-healing like the others.
func (s *server) handleActivityList(w http.ResponseWriter, r *http.Request) {
	events, err := s.recentActivity(r.Context())
	if err != nil {
		s.render(w, "activity-list", activityData{Flash: errorFlash("API error: " + err.Error())})
		return
	}
	s.render(w, "activity-list", activityData{Events: events})
}
