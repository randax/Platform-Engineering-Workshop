package kube

// Package kube is the portal's entire Kubernetes access layer — on purpose.
//
// Portals and dashboards are often assumed to need client-go, informers and
// code generation. For *reading* a handful of resources they don't: the
// Kubernetes API is plain HTTPS + JSON, and every pod already has credentials
// for it. Three things make in-cluster access work:
//
//  1. the API server address is injected as env vars (KUBERNETES_SERVICE_HOST/_PORT),
//  2. a bearer token for the pod's ServiceAccount is mounted at
//     /var/run/secrets/kubernetes.io/serviceaccount/token,
//  3. the cluster CA certificate is mounted next to it, so we can verify TLS.
//
// What the token is *allowed* to do is decided by RBAC on the ServiceAccount
// (see the portal's Role/ClusterRole in the gitops manifests). That's it —
// roughly 50 lines, zero dependencies.

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

const saDir = "/var/run/secrets/kubernetes.io/serviceaccount"

type Client struct {
	baseURL string // e.g. https://10.96.0.1:443
	token   string // ServiceAccount bearer token ("" when going via kubectl proxy)
	client  *http.Client
}

// NewClient wires up in-cluster API access. For local development run
// `kubectl proxy` and pass its URL (config: KUBE_API_URL) — the proxy
// injects your own credentials, so no token is needed.
func NewClient(apiURL, token string) (*Client, error) {
	if apiURL != "" {
		return &Client{
			baseURL: strings.TrimSuffix(apiURL, "/"),
			token:   token,
			client: &http.Client{
				Timeout:   10 * time.Second,
				Transport: otelhttp.NewTransport(nil), // child span per API call
			},
		}, nil
	}

	host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
	if host == "" {
		return nil, fmt.Errorf("KUBERNETES_SERVICE_HOST not set: not running in a cluster")
	}
	caPEM, err := os.ReadFile(saDir + "/ca.crt")
	if err != nil {
		return nil, fmt.Errorf("reading cluster CA: %w", err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(caPEM)

	saToken, err := os.ReadFile(saDir + "/token")
	if err != nil {
		return nil, fmt.Errorf("reading serviceaccount token: %w", err)
	}
	return &Client{
		baseURL: "https://" + net.JoinHostPort(host, port),
		token:   strings.TrimSpace(string(saToken)),
		client: &http.Client{
			Timeout: 10 * time.Second,
			// otelhttp wraps the real transport so every API call shows up
			// as a child span in the page's trace.
			Transport: otelhttp.NewTransport(
				&http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}),
		},
	}, nil
}

// do performs one API request. path is a full API path such as
// "/apis/argoproj.io/v1alpha1/applications"; out, when non-nil, receives the
// decoded JSON response. The context carries the caller's trace span.
func (k *Client) do(ctx context.Context, method, path string, body io.Reader, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, k.baseURL+path, body)
	if err != nil {
		return err
	}
	if k.token != "" {
		req.Header.Set("Authorization", "Bearer "+k.token)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := k.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return &apiError{
			Status: resp.StatusCode,
			Msg:    fmt.Sprintf("%s %s: %s: %s", method, path, resp.Status, strings.TrimSpace(string(msg))),
		}
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (k *Client) get(ctx context.Context, path string, out any) error {
	return k.do(ctx, http.MethodGet, path, nil, out)
}

// apiError keeps the HTTP status so callers can tell "does not exist" (a
// normal answer) apart from "something is broken".
type apiError struct {
	Status int
	Msg    string
}

func (e *apiError) Error() string { return e.Msg }

func isNotFound(err error) bool {
	var ae *apiError
	return errors.As(err, &ae) && ae.Status == http.StatusNotFound
}
