package registry

// Package registry is the portal's read-only client for an OCI Distribution
// registry — Zot, in module 07's in-cluster CI. "The registry API" sounds
// like something proprietary; it isn't. It's the OCI Distribution spec, and
// the two calls this console needs are plain HTTP GETs under /v2/:
//
//	GET /v2/_catalog           → {"repositories":[...]}   the images you've built
//	GET /v2/<repo>/tags/list   → {"tags":[...]}           the tags on one repo
//
// No auth (the workshop's Zot is anonymous read/write), no SDK, no generated
// client — the same "it's just HTTP + JSON" lesson as the kube package next
// door. The whole client is ~50 lines and zero third-party dependencies.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// Client talks to one registry's HTTP API.
type Client struct {
	baseURL string
	http    *http.Client
}

// New builds a client for the registry at baseURL (e.g.
// http://zot.zot.svc.cluster.local:5000). The 5s timeout keeps a sleepy or
// absent registry from hanging the Builds page — the handler degrades in
// place on any error.
func New(baseURL string) *Client {
	return &Client{
		baseURL: strings.TrimSuffix(baseURL, "/"),
		http: &http.Client{
			Timeout: 5 * time.Second,
			// otelhttp wraps the transport so each registry call shows up as a
			// child span in the page's trace, exactly like the kube client.
			Transport: otelhttp.NewTransport(nil),
		},
	}
}

// Repo is one repository in the catalog, paired with its tags. Tags is
// best-effort: the repo always lists even if its per-repo tags call fails.
type Repo struct {
	Name string
	Tags []string
}

// Catalog lists the registry's repositories, then fills in each one's tags.
// That's one GET for the catalog plus one GET per repo — fine for a teaching
// registry with a handful of images; a real one would paginate _catalog.
func (c *Client) Catalog(ctx context.Context) ([]Repo, error) {
	var cat struct {
		Repositories []string `json:"repositories"`
	}
	if err := c.get(ctx, "/v2/_catalog", &cat); err != nil {
		return nil, err
	}
	repos := make([]Repo, 0, len(cat.Repositories))
	for _, name := range cat.Repositories {
		repo := Repo{Name: name}
		// Tags are decoration: one repo's failed tag listing must not sink the
		// whole catalog, so on error the repo simply renders tag-less.
		if tags, err := c.tags(ctx, name); err == nil {
			repo.Tags = tags
		}
		repos = append(repos, repo)
	}
	return repos, nil
}

func (c *Client) tags(ctx context.Context, repo string) ([]string, error) {
	var out struct {
		Tags []string `json:"tags"`
	}
	err := c.get(ctx, "/v2/"+repo+"/tags/list", &out)
	return out.Tags, err
}

// get performs one registry GET and decodes the JSON body into out.
func (c *Client) get(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("GET %s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
