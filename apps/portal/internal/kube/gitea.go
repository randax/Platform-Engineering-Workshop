package kube

// Console → Gitea scaffold bridge (PRD-0012). "Console creates the repo": the
// New-application form can start an app from a template — the portal calls
// Gitea's generate API to fork the sample into a fresh tenant repo, then builds
// and deploys THAT repo through the same deploy-from-source path.
//
// This is the one deliberate exception to DR-0004's "the console doesn't write
// to the git plane": scaffolding a repo IS a git-plane write, but it's a
// one-time bootstrap of the developer's OWN space (not a platform change), and
// it's what makes "start a new app" feel connected instead of a context switch
// into Gitea's UI. The repo, once created, is the developer's to push to.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// GiteaOrg is the org the console scaffolds tenant app repos into — the same org
// that owns the platform repo and the demo-app template.
const GiteaOrg = "cloudbox"

// DefaultTemplate is the sample the console scaffolds from — the demo app,
// seeded into Gitea as a template repo by scripts/seed-gitea.sh.
const DefaultTemplate = GiteaOrg + "/demo-app"

// giteaHTTP talks to Gitea's REST API (a different host and auth from the k8s
// API, so it's a plain client, not k.do). giteaBase is http, so no TLS config.
var giteaHTTP = &http.Client{Timeout: 15 * time.Second}

// GiteaConfigured reports whether the portal has Gitea credentials — the
// scaffold-from-template option is only offered when it does.
func GiteaConfigured() bool {
	return os.Getenv("GITEA_USER") != "" && os.Getenv("GITEA_PASSWORD") != ""
}

// ScaffoldRepo generates a new repo GiteaOrg/<name> from the template
// "<org>/<repo>" via Gitea's generate API, copying the template's files. It
// returns the new "<org>/<name>" reference (ready to build from source). The
// credentials come from GITEA_USER/GITEA_PASSWORD (the lab's fixed gitea_admin,
// wired in portal.yaml like the S3 creds).
func (k *Client) ScaffoldRepo(ctx context.Context, template, name string) (string, error) {
	if !ValidName(name) {
		return "", fmt.Errorf("app name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	if !orgRepoRe.MatchString(template) {
		return "", fmt.Errorf("template must be <org>/<repo> in the in-cluster Gitea, got %q", template)
	}
	user, pass := os.Getenv("GITEA_USER"), os.Getenv("GITEA_PASSWORD")
	if user == "" || pass == "" {
		return "", fmt.Errorf("repo scaffolding isn't configured on this portal (no Gitea credentials)")
	}
	payload, err := json.Marshal(map[string]any{
		"owner":       GiteaOrg,
		"name":        name,
		"private":     false,
		"git_content": true,
		"description": "Scaffolded from " + template + " by the Cloudbox console",
	})
	if err != nil {
		return "", err
	}
	url := giteaBase + "/api/v1/repos/" + template + "/generate"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.SetBasicAuth(user, pass)

	resp, err := giteaHTTP.Do(req)
	if err != nil {
		return "", fmt.Errorf("reaching Gitea: %w", err)
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusCreated:
		return GiteaOrg + "/" + name, nil
	case http.StatusConflict:
		return "", fmt.Errorf("a repo named %q already exists in %s — pick another name", name, GiteaOrg)
	case http.StatusNotFound:
		return "", fmt.Errorf("template %q not found (is it seeded and marked a template?)", template)
	case http.StatusUnprocessableEntity:
		return "", fmt.Errorf("%q isn't a template repo — mark it as one in Gitea first", template)
	default:
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("gitea generate failed (%s): %s", resp.Status, string(body))
	}
}
