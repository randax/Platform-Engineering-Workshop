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
	"time"

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
			{"POST /applications/{name}/redeploy", handleRedeployApplication},
			{"DELETE /applications/{name}", handleDeleteApplication},
		},
	})
}

// appRow decorates an Application XR with the URL its composed Knative Service
// answers on (Knative programs <name>.<ns>.sslip.io, reachable via Kourier's
// NodePort 31080) — shown once the app is Ready.
type appRow struct {
	kube.Application
	URL         string
	SourceBuilt bool   // built from a Gitea repo → offer Redeploy
	Why         string // failing-condition cause when not Ready (DR-0005)
}

type applicationsData struct {
	Apps            []appRow
	Flash           flash
	ScaffoldEnabled bool             // portal has Gitea creds → offer "start from a template"
	Diag            kube.Diagnostics // project-namespace "why unhealthy" (DR-0005)
	ShowDiag        bool
}

func fetchApplications(ctx context.Context, s *Server, ns string, fl flash) (applicationsData, error) {
	apps, err := s.Kube.ListApplications(ctx, ns)
	if err != nil {
		return applicationsData{}, err
	}
	rows := make([]appRow, 0, len(apps))
	anyUnhealthy := false
	for _, a := range apps {
		_, _, _, sourceBuilt := a.Source()
		row := appRow{Application: a, SourceBuilt: sourceBuilt}
		if a.Readiness().Class == "ok" {
			// The sslip.io URL the composed ksvc serves on, via Kourier's NodePort.
			row.URL = fmt.Sprintf("http://%s.%s.127.0.0.1.sslip.io:31080", a.Metadata.Name, a.Metadata.Namespace)
		} else {
			row.Why = a.Why() // the Crossplane cause, shown inline (DR-0005)
			anyUnhealthy = true
		}
		rows = append(rows, row)
	}
	data := applicationsData{Apps: rows, Flash: fl, ScaffoldEnabled: kube.GiteaConfigured()}
	// When something's wrong, add the project-namespace "why" (failing pods +
	// Warning events) below the table — the cause a describe would show. Best
	// effort: a diag read error never breaks the page.
	if anyUnhealthy {
		if diag, derr := s.Kube.NamespaceDiagnostics(ctx, ns); derr == nil {
			data.Diag = diag
			data.ShowDiag = !diag.Empty()
		}
	}
	return data, nil
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

// deployApplication handles all three sources: a prebuilt container image; a
// Gitea repo the platform builds first (the app-team golden path); or a template
// the console scaffolds into a fresh repo and THEN builds (scaffold bridge,
// PRD-0012). Source-built paths build first (nothing to run without an image),
// then create the XR, which composes the workload + database + bucket and
// converges from ImagePullBackOff once the build lands.
func deployApplication(s *Server, r *http.Request, ns, name string, opts kube.AppOpts) flash {
	switch r.FormValue("source") {
	case "template":
		// "Console creates the repo": scaffold GiteaOrg/<name> from the template,
		// then deploy from source off the new repo's main branch.
		tmpl := r.FormValue("template")
		if tmpl == "" {
			tmpl = kube.DefaultTemplate
		}
		repoRef, err := s.Kube.ScaffoldRepo(r.Context(), tmpl, name)
		if err != nil {
			return errorFlash("Couldn't create the repo from the template: " + err.Error())
		}
		fl := buildFromRepo(s, r, ns, name, opts, repoRef, "main", ".")
		if !fl.Error {
			fl.Msg = "Scaffolded " + repoRef + " from " + tmpl + ". " + fl.Msg
		}
		return fl
	case "repo":
		return buildFromRepo(s, r, ns, name, opts, r.FormValue("repo"), r.FormValue("branch"), r.FormValue("path"))
	}
	if err := s.Kube.CreateApplication(r.Context(), ns, name, opts); err != nil {
		return errorFlash("Deploy failed: " + err.Error())
	}
	return flash{Msg: "Deploying " + name + " — Crossplane is composing the workload, its database and bucket. Watch it turn Ready below."}
}

// buildFromRepo is the deploy-from-source path shared by the "repo" and
// "template" sources: build the image from the Gitea repo (<org>/<repo>), then
// create the Application at that image with the source recorded for Redeploy.
func buildFromRepo(s *Server, r *http.Request, ns, name string, opts kube.AppOpts, repoRef, branch, path string) flash {
	repoURL, err := kube.GiteaRepoURL(repoRef)
	if err != nil {
		return errorFlash(err.Error())
	}
	if path == "" {
		path = "."
	}
	if branch == "" {
		branch = "main"
	}
	tag := newBuildTag()
	if err := s.Kube.CreateAppBuildWorkflow(r.Context(), name, repoURL, branch, path, tag); err != nil {
		return errorFlash("Couldn't start the build: " + err.Error())
	}
	opts.Image = kube.AppSourcePullImage(name, tag)
	opts.Source = &kube.AppSource{Repo: repoURL, Branch: branch, Path: path}
	if err := s.Kube.CreateApplication(r.Context(), ns, name, opts); err != nil {
		return errorFlash("Build started, but deploying the app failed: " + err.Error())
	}
	return flash{Msg: "Building app-" + name + " from " + repoRef + " and deploying it — workload + database + bucket. Watch the build on the Builds page; the row turns Ready once the image lands (~1 min)."}
}

// newBuildTag is a unique image tag per build — so a rebuild pushes a NEW tag,
// which changes the workload's spec.image → a fresh Knative revision → the new
// code actually rolls out. UnixNano makes back-to-back rebuilds distinct.
func newBuildTag() string { return "b" + strconv.FormatInt(time.Now().UnixNano(), 36) }

// handleRedeployApplication rebuilds a source-built app from its recorded repo
// (a new tag) and patches the workload to the new image — the iterate loop:
// push new code, hit Redeploy, the running app rolls forward.
func handleRedeployApplication(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	ns := s.activeProject(r)
	fl := redeployApplication(s, r, ns, name)
	data, err := fetchApplications(r.Context(), s, ns, fl)
	if err != nil {
		data = applicationsData{Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "app-list", data)
}

func redeployApplication(s *Server, r *http.Request, ns, name string) flash {
	app, err := s.Kube.GetApplication(r.Context(), ns, name)
	if err != nil {
		return errorFlash("Lookup failed: " + err.Error())
	}
	if app == nil {
		return errorFlash("No such application: " + name)
	}
	repo, branch, path, ok := app.Source()
	if !ok {
		return errorFlash(name + " wasn't built from source, so there's nothing to rebuild — it runs a prebuilt image.")
	}
	tag := newBuildTag()
	if err := s.Kube.CreateAppBuildWorkflow(r.Context(), name, repo, branch, path, tag); err != nil {
		return errorFlash("Couldn't start the rebuild: " + err.Error())
	}
	if err := s.Kube.SetApplicationImage(r.Context(), ns, name, kube.AppSourcePullImage(name, tag)); err != nil {
		return errorFlash("Rebuild started, but rolling the app failed: " + err.Error())
	}
	return flash{Msg: "Rebuilding " + name + " from " + repo + " and rolling it forward. Watch the build on the Builds page; the new revision goes live once the image lands (~1 min)."}
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
