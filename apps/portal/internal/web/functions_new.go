package web

// The New Function page (issue #58): the console's Lambda-style create-flow.
// Modules 06 and 07 taught the two halves separately — build an image in-cluster
// (Argo + BuildKit + Zot), and run one as a scale-to-zero Knative Service. This
// page ties them into one form: pick a source, name it, and the platform builds
// your image and deploys it as a function URL. No CLI, no client-go — two
// hand-written objects POSTed to the API (see kube/functions.go), then Kubernetes
// converges. Progress shows on the existing Builds and Services pages.

import (
	"net/http"

	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		// Weight 65: Self-service, between Databases (60) and Services (70) —
		// the function you create lands on the Services page right below.
		Weight:     65,
		NavSection: "Self-service",
		NavTitle:   "New Function",
		Path:       "/functions/new",
		Handler:    handleNewFunction,
		// Needs BOTH capabilities: Argo Workflows (module 07) to build the image
		// and Knative (module 06) to run it. Locked until both are Healthy.
		Unlock: func(s kube.Snapshot) bool {
			_, wf := s.AppHealthy("argo-workflows")
			_, kn := s.AppHealthy("knative-serving")
			return wf && kn
		},
		LockedHint: "Complete Modules 06 + 07",
		Teaser:     "Turn source into a scale-to-zero function URL — the platform builds your image in-cluster and deploys it, no CLI.",
		// Mutating route. Like the databases form, no CSRF token — single-user
		// disposable lab; don't copy this into a real portal.
		Extra: []Route{
			{"POST /functions", handleCreateFunction},
		},
	})
}

// fnSample is one vetted, in-cluster source a function can be built from. The
// repo MUST be an in-cluster Gitea URL (never github.com) — the whole platform
// is offline, and BuildKit clones from inside the cluster. Server-side
// whitelist: the browser only ever submits a key, never a raw repo/path, so a
// crafted form can't point a build at an arbitrary URL.
type fnSample struct {
	Key, Label, Repo, Path, Desc string
}

var fnSamples = []fnSample{
	{
		Key:   "hello-site",
		Label: "hello-site — static page on busybox httpd",
		Repo:  "http://gitea-http.gitea.svc.cluster.local:3000/cloudbox/platform.git",
		Path:  "lab/07-ci/app",
		Desc:  "Module 07's sample: a tiny static site, built FROM your own Zot registry and served on :8080.",
	},
}

func lookupSample(key string) (fnSample, bool) {
	for _, s := range fnSamples {
		if s.Key == key {
			return s, true
		}
	}
	return fnSample{}, false
}

type functionsNewData struct {
	Samples []fnSample
	Flash   flash
}

func handleNewFunction(s *Server, w http.ResponseWriter, r *http.Request) {
	s.render(w, "functions-new", functionsNewData{Samples: fnSamples})
}

// handleCreateFunction is the fan-out: one submit creates the build Workflow AND
// the Knative Service. We create the build first (nothing to run without an
// image); if that's forbidden (the attendee hasn't granted the portal write
// access yet) we stop there with a friendly flash. The ksvc is admitted
// immediately (its image host is in Knative's tag-resolution skip list) and
// converges from ImagePullBackOff to Ready the moment the build pushes.
func handleCreateFunction(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	sample, ok := lookupSample(r.FormValue("sample"))
	if !ok {
		s.render(w, "fn-result", functionsNewData{Flash: errorFlash("Unknown source — pick one of the listed samples.")})
		return
	}

	if err := s.Kube.CreateFunctionWorkflow(r.Context(), name, sample.Repo, sample.Path); err != nil {
		s.render(w, "fn-result", functionsNewData{Flash: errorFlash("Couldn't start the build: " + err.Error())})
		return
	}
	if err := s.Kube.CreateFunctionService(r.Context(), name); err != nil {
		// The build is already running; only the deploy half failed. Say so —
		// re-submitting after granting access will create the ksvc, and the
		// finished image is waiting for it.
		s.render(w, "fn-result", functionsNewData{Flash: errorFlash("Build started, but deploying the function failed: " + err.Error())})
		return
	}
	s.render(w, "fn-result", functionsNewData{Flash: flash{
		Msg: "Building fn-" + name + " and deploying it as a Knative Service. Watch the build on the Builds page; the function URL appears on the Services page once the image lands (~1 min).",
	}})
}
