package kube

// Kubernetes Events — the cluster's built-in activity log. The Activity
// page and the database detail page both read from here.

import (
	"context"
	"fmt"
	"net/url"
	"sort"
	"time"
)

// Event is the slice of a core/v1 Event the pages show.
type Event struct {
	Metadata       ObjMeta `json:"metadata"`
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
func (e Event) when() time.Time {
	for _, s := range []string{e.LastTimestamp, e.EventTime, e.Metadata.CreationTimestamp} {
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			return t
		}
	}
	return time.Time{}
}

// Age renders "how long ago" the way consoles do.
func (e Event) Age() string {
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

// ListEvents fetches events from one API path (cluster-wide or namespaced,
// optionally with a fieldSelector), newest first.
func (k *Client) ListEvents(ctx context.Context, path, fieldSelector string) ([]Event, error) {
	if fieldSelector != "" {
		path += "?fieldSelector=" + url.QueryEscape(fieldSelector)
	}
	var list struct {
		Items []Event `json:"items"`
	}
	if err := k.get(ctx, path, &list); err != nil {
		return nil, err
	}
	sort.Slice(list.Items, func(i, j int) bool { return list.Items[i].when().After(list.Items[j].when()) })
	return list.Items, nil
}
