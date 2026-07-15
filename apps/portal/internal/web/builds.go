package web

// The Builds page: module 07's in-cluster CI, seen read-only from the console.
// Two data sources, two small lessons, zero magic:
//
//   - Recent runs come from Argo Workflows. A `Workflow` is just another
//     argoproj.io CRD, so listing runs is the same authenticated GET this
//     console already uses for ArgoCD Applications and Knative Services.
//   - The registry catalog comes from Zot over the OCI Distribution API —
//     GET /v2/_catalog and /v2/<repo>/tags/list, plain HTTP + JSON, no SDK.
//
// Both halves degrade in place: a failing source shows an error flash inside
// its own section while the other keeps rendering, and the fragment keeps
// polling — the same contract as the databases/gallery fragments.

import (
	"context"
	"log"
	"net/http"

	"cloudbox.io/portal/internal/kube"
	reg "cloudbox.io/portal/internal/registry" // aliased: this package already has a `registry` var (the page registry)
)

func init() {
	register(Page{
		// Weight 55 keeps Builds at the tail of the Platform group (after
		// Billing 50, before Self-service opens at 60), so the sidebar sections
		// stay contiguous — CI is a platform capability, not a per-user tool.
		Weight:     55,
		NavSection: "Platform",
		NavTitle:   "Builds",
		Path:       "/builds",
		Handler:    handleBuilds,
		// CI (module 07): until Argo Workflows is installed and Healthy there is
		// no /workflows endpoint to list and no registry to read — the page
		// would only error, so it stays locked behind the same mechanic as the
		// other capability pages.
		Unlock:     func(s kube.Snapshot) bool { _, h := s.AppHealthy("argo-workflows"); return h },
		LockedHint: "Complete Module 07 · CI",
		Teaser:     "Watch your in-cluster CI: recent Argo Workflows build runs and the Zot registry catalog they push images to.",
		Extra: []Route{
			{"GET /builds/runs", handleBuildRuns}, // polled by htmx
		},
	})
}

// workflowLister and catalogLister are the two slices of the world this page
// consumes — consumer-side interfaces, so the rendering is testable with
// fakes instead of a live Argo Workflows and Zot. *kube.Client and
// *registry.Client satisfy them in production.
type workflowLister interface {
	ListArgoWorkflows(ctx context.Context) ([]kube.Workflow, error)
}

type catalogLister interface {
	Catalog(ctx context.Context) ([]reg.Repo, error)
}

// buildsData backs both the full page and the polled fragment. Each source
// carries its own flash, so one failing (say, Zot is asleep) never blanks the
// other — the working half still renders its section.
type buildsData struct {
	Workflows []kube.Workflow
	Repos     []reg.Repo
	WFFlash   flash // set when the Argo Workflows read fails
	RepoFlash flash // set when the registry read fails
}

// gatherBuilds reads both sources independently. Neither error is fatal: a
// dead source becomes a flash in its own section (degrade in place, like the
// buckets/gallery fragments), so the page always renders something useful.
func gatherBuilds(ctx context.Context, wl workflowLister, cl catalogLister) buildsData {
	var data buildsData
	if wfs, err := wl.ListArgoWorkflows(ctx); err != nil {
		log.Printf("list workflows: %v", err)
		data.WFFlash = errorFlash("Argo Workflows API error: " + err.Error())
	} else {
		data.Workflows = wfs
	}
	if repos, err := cl.Catalog(ctx); err != nil {
		log.Printf("registry catalog: %v", err)
		data.RepoFlash = errorFlash("Registry error: " + err.Error())
	} else {
		data.Repos = repos
	}
	return data
}

func handleBuilds(s *Server, w http.ResponseWriter, r *http.Request) {
	s.render(w, "builds", gatherBuilds(r.Context(), s.Kube, s.Registry))
}

// handleBuildRuns serves the self-refreshing fragment htmx polls. Same
// degrade-in-place contract as the databases/gallery fragments: any error is
// already folded into buildsData as a flash, so the polling attributes stay in
// the DOM and each section heals itself once its API answers again.
func handleBuildRuns(s *Server, w http.ResponseWriter, r *http.Request) {
	s.render(w, "builds-runs", gatherBuilds(r.Context(), s.Kube, s.Registry))
}
