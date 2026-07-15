package logs

// Package logs: a recent-log tail without a logging UI stack. The teaching beat
// of this file, twin to internal/metrics: a console's "Logs" tab is one HTTP GET
// (VictoriaLogs's /select/logsql/query) that streams back JSON lines — that is
// what sits behind the chrome of every cloud console's log view.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type Client struct {
	base string
	http *http.Client
}

func New(vlogsURL string) *Client {
	return &Client{
		base: strings.TrimSuffix(vlogsURL, "/"),
		// Short timeout: a log tail is a convenience panel, never worth a slow
		// page (same posture as the metrics client).
		http: &http.Client{Timeout: 3 * time.Second},
	}
}

// Line is one log record: when it happened and the message.
type Line struct {
	Time time.Time
	Msg  string
}

// NamespaceFilter is a LogsQL stream filter for a whole namespace, and
// PodFilter for one pod. The field names are the stream fields the OTel
// Collector agent sets via VL-Stream-Fields (k8s.namespace.name / k8s.pod.name);
// `:=` is LogsQL exact-value equality. Values are quoted so a name never breaks
// the query syntax.
func NamespaceFilter(namespace string) string {
	return fmt.Sprintf(`k8s.namespace.name:=%s`, strconv.Quote(namespace))
}

func PodFilter(namespace, pod string) string {
	return fmt.Sprintf(`k8s.namespace.name:=%s k8s.pod.name:=%s`,
		strconv.Quote(namespace), strconv.Quote(pod))
}

// Tail runs a LogsQL filter over the last `window` and returns up to `limit`
// most-recent lines, newest first. No matching logs is a normal state (component
// idle, telemetry not enabled) and returns nil, nil — the caller renders an
// empty-state hint, never an error.
func (c *Client) Tail(ctx context.Context, filter string, window time.Duration, limit int) ([]Line, error) {
	// Compose: time window + caller's filter, then sort newest-first and cap.
	// e.g. `_time:60m k8s.namespace.name:="argocd" | sort by (_time) desc | limit 50`
	q := fmt.Sprintf(`_time:%dm %s | sort by (_time) desc | limit %d`,
		int(window.Minutes()), filter, limit)
	params := url.Values{"query": {q}, "limit": {strconv.Itoa(limit)}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.base+"/select/logsql/query?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("victoria-logs: %s", resp.Status)
	}

	// The response is JSON lines: one object per log record, with the default
	// _time / _msg fields (plus stream fields we don't need here).
	var lines []Line
	sc := bufio.NewScanner(resp.Body)
	// Log lines can be long; give the scanner a generous buffer.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		b := sc.Bytes()
		if len(b) == 0 {
			continue
		}
		var rec struct {
			Time string `json:"_time"`
			Msg  string `json:"_msg"`
		}
		if err := json.Unmarshal(b, &rec); err != nil {
			continue // skip a malformed line rather than fail the whole tail
		}
		t, _ := time.Parse(time.RFC3339Nano, rec.Time)
		lines = append(lines, Line{Time: t, Msg: rec.Msg})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return lines, nil
}
