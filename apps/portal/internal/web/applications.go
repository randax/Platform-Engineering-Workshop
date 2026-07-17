package web

// The Applications page: the golden path (PRD-0003) as a console action. One
// form deploys an Application XR — a workload plus a Postgres database and an S3
// bucket, wired together by Crossplane. This is the apex of the self-service
// arc: the New-database and New-function forms provision one thing; this
// provisions an app AND its dependencies from a single POST.

import (
	"context"
	"fmt"
	"net/http"
	"strconv"

	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		// Weight 54 puts Applications first in the Services section — it's the
		// headline "deploy an app" action, above the single-resource forms.
		Weight:     54,
		NavSection: "Services",
		NavTitle:   "Applications",
		Path:       "/applications",
		Handler:    handleApplications,
		// The golden-path XR only exists once the application-xr catalog item is
		// enabled and Healthy — before that the CRD isn't there to create.
		Unlock:     func(s kube.Snapshot) bool { _, h := s.AppHealthy("application-xr"); return h },
		LockedHint: "Enable application-xr from the catalog",
		Teaser:     "Deploy an app and its dependencies from one form — a workload, a Postgres database and an S3 bucket, composed and wired together by Crossplane.",
		// Mutating routes; console-direct writes (DR-0004), no CSRF token
		// (single-user disposable lab).
		Extra: []Route{
			{"GET /applications/list", handleApplicationsList},
			{"POST /applications", handleCreateApplication},
			{"DELETE /applications/{name}", handleDeleteApplication},
		},
	})
}

// appRow decorates an Application XR with the URL its composed Knative Service
// answers on (Knative programs <name>.<ns>.sslip.io, reachable via Kourier's
// NodePort 31080) — shown once the app is Ready.
type appRow struct {
	kube.Application
	URL string
}

type applicationsData struct {
	Apps  []appRow
	Flash flash
}

func fetchApplications(ctx context.Context, s *Server, ns string, fl flash) (applicationsData, error) {
	apps, err := s.Kube.ListApplications(ctx, ns)
	if err != nil {
		return applicationsData{}, err
	}
	rows := make([]appRow, 0, len(apps))
	for _, a := range apps {
		row := appRow{Application: a}
		if a.Readiness().Class == "ok" {
			// The sslip.io URL the composed ksvc serves on, via Kourier's NodePort.
			row.URL = fmt.Sprintf("http://%s.%s.127.0.0.1.sslip.io:31080", a.Metadata.Name, a.Metadata.Namespace)
		}
		rows = append(rows, row)
	}
	return applicationsData{Apps: rows, Flash: fl}, nil
}

func handleApplications(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchApplications(r.Context(), s, s.activeProject(r), flash{})
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "applications", data)
}

func handleApplicationsList(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchApplications(r.Context(), s, s.activeProject(r), flash{})
	if err != nil {
		data = applicationsData{Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "app-list", data)
}

// handleCreateApplication turns the form into an Application XR — the golden
// path in one POST. Crossplane composes the workload, database and bucket; the
// row turns Ready as they converge. Answers with the refreshed list fragment.
func handleCreateApplication(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	ns := s.activeProject(r)
	fl := deployApplication(s, r, ns, name, parseAppOpts(r))
	data, err := fetchApplications(r.Context(), s, ns, fl)
	if err != nil {
		data = applicationsData{Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "app-list", data)
}

// deployApplication handles both sources: a prebuilt container image, or — the
// app-team golden path — a Gitea repo the platform builds first (build → push
// to Zot → deploy the Application at the built image). Build first (nothing to
// run without an image), then the XR, which composes the workload + database +
// bucket and converges from ImagePullBackOff once the build lands.
func deployApplication(s *Server, r *http.Request, ns, name string, opts kube.AppOpts) flash {
	if r.FormValue("source") == "repo" {
		repoURL, err := kube.GiteaRepoURL(r.FormValue("repo"))
		if err != nil {
			return errorFlash(err.Error())
		}
		path := r.FormValue("path")
		if path == "" {
			path = "."
		}
		if err := s.Kube.CreateAppBuildWorkflow(r.Context(), name, repoURL, r.FormValue("branch"), path); err != nil {
			return errorFlash("Couldn't start the build: " + err.Error())
		}
		opts.Image = kube.AppSourcePullImage(name)
		if err := s.Kube.CreateApplication(r.Context(), ns, name, opts); err != nil {
			return errorFlash("Build started, but deploying the app failed: " + err.Error())
		}
		return flash{Msg: "Building app-" + name + " from your repo and deploying it — workload + database + bucket. Watch the build on the Builds page; the row turns Ready once the image lands (~1 min)."}
	}
	if err := s.Kube.CreateApplication(r.Context(), ns, name, opts); err != nil {
		return errorFlash("Deploy failed: " + err.Error())
	}
	return flash{Msg: "Deploying " + name + " — Crossplane is composing the workload, its database and bucket. Watch it turn Ready below."}
}

func handleDeleteApplication(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	ns := s.activeProject(r)
	fl := flash{Msg: "Deleted " + name + " — its composed workload, database and bucket are being removed."}
	if err := s.Kube.DeleteApplication(r.Context(), ns, name); err != nil {
		fl = errorFlash("Delete failed: " + err.Error())
	}
	data, err := fetchApplications(r.Context(), s, ns, fl)
	if err != nil {
		data = applicationsData{Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "app-list", data)
}

// parseAppOpts reads the rich create form: image, min/max scale, env rows, and
// the database/bucket toggles.
func parseAppOpts(r *http.Request) kube.AppOpts {
	_ = r.ParseForm()
	names, values := r.Form["env_name"], r.Form["env_value"]
	env := make([]kube.AppEnv, 0, len(names))
	for i, n := range names {
		v := ""
		if i < len(values) {
			v = values[i]
		}
		env = append(env, kube.AppEnv{Name: n, Value: v})
	}
	min, _ := strconv.Atoi(r.FormValue("min"))
	max, _ := strconv.Atoi(r.FormValue("max"))
	return kube.AppOpts{
		Image:    r.FormValue("image"),
		MinScale: min,
		MaxScale: max,
		Env:      env,
		Database: r.FormValue("database") != "",
		Bucket:   r.FormValue("bucket") != "",
	}
}
