package nats

// Package nats browses JetStream through NATS's monitoring endpoint — no NATS
// client library, just one HTTP GET, in the same "a console is only API calls"
// spirit as internal/store (S3) and internal/metrics (Prometheus).
//
// The teaching beat: module 09's in-memory broker is ephemeral — restart it and
// the messages are gone. JetStream is its durable counterpart: streams persist
// messages to disk, and consumers track their own position through them. This
// package inspects that durability from the outside. Every NATS server ships a
// read-only monitoring server on :8222; GET /jsz?streams=1&consumers=1 returns
// the whole JetStream picture as JSON. That's it — no auth, no protocol, no
// subscription. What a "real" JetStream dashboard shows, minus the machinery.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

// Stream is one JetStream stream, reduced to the four columns the browser
// shows. The web layer never imports this package's wire types — it gets these
// plain values, exactly as it gets store.ObjectInfo rather than minio's structs.
type Stream struct {
	Name      string // stream name (its config.name)
	Messages  uint64 // messages currently retained
	Bytes     uint64 // bytes on disk for those messages
	Consumers int    // durable/ephemeral consumers reading the stream
}

// HumanBytes renders the stream's on-disk size the way a file manager would —
// the same humanization the bucket browser uses on object sizes.
func (s Stream) HumanBytes() string {
	b := float64(s.Bytes)
	switch {
	case s.Bytes >= 1<<20:
		return fmt.Sprintf("%.1f MB", b/(1<<20))
	case s.Bytes >= 1<<10:
		return fmt.Sprintf("%.0f KB", b/(1<<10))
	default:
		return fmt.Sprintf("%d B", s.Bytes)
	}
}

// Client GETs the NATS monitoring endpoint. Like the Prometheus client, it
// holds a base URL and a short-timeout http.Client — a stream listing is a
// dashboard read, never worth hanging the page on.
type Client struct {
	base string
	http *http.Client
}

// New builds a client for the NATS monitoring base URL (e.g.
// http://nats.nats.svc.cluster.local:8222). The trailing slash is trimmed so
// path joins stay clean, mirroring metrics.New.
func New(monitorURL string) *Client {
	return &Client{
		base: strings.TrimSuffix(monitorURL, "/"),
		http: &http.Client{Timeout: 3 * time.Second},
	}
}

// jsz mirrors the slice of /jsz we care about. NATS returns far more (cluster
// info, raw config, per-consumer detail); we decode only the account →
// stream_detail → {config.name, state} path and let encoding/json drop the rest.
type jsz struct {
	AccountDetails []struct {
		StreamDetail []struct {
			Config struct {
				Name string `json:"name"`
			} `json:"config"`
			State struct {
				Messages      uint64 `json:"messages"`
				Bytes         uint64 `json:"bytes"`
				ConsumerCount int    `json:"consumer_count"`
			} `json:"state"`
		} `json:"stream_detail"`
	} `json:"account_details"`
}

// ListStreams returns every JetStream stream across every account, the /jsz
// shape flattened into []Stream and sorted by name for a stable table.
//
// "JetStream empty" is a first-class, non-error state: a NATS server with
// JetStream enabled but no streams yet — or with JetStream not enabled at all —
// answers /jsz with 200 and simply no account/stream detail. That returns
// (nil, nil), and the page shows a friendly empty state, never an error. Only a
// genuine failure (endpoint unreachable, non-200, unparseable body) is an error.
func (c *Client) ListStreams(ctx context.Context) ([]Stream, error) {
	// streams=1 asks for per-stream detail; consumers=1 populates each stream's
	// consumer_count. Without these flags /jsz returns only account totals.
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.base+"/jsz?streams=1&consumers=1", nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("nats monitoring returned %s", resp.Status)
	}

	var body jsz
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}

	var streams []Stream
	for _, acct := range body.AccountDetails {
		for _, sd := range acct.StreamDetail {
			streams = append(streams, Stream{
				Name:      sd.Config.Name,
				Messages:  sd.State.Messages,
				Bytes:     sd.State.Bytes,
				Consumers: sd.State.ConsumerCount,
			})
		}
	}
	// Stable order: map/account iteration on the server side is not ordered, and
	// a table that reshuffles on every 5s poll is unreadable.
	sort.Slice(streams, func(i, j int) bool { return streams[i].Name < streams[j].Name })
	return streams, nil
}
