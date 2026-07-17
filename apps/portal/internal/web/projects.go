package web

// Projects (PRD-0011): the top-bar project selector + create/switch/delete.
// These are GLOBAL chrome, not registry pages, so main.go mounts them directly.
// The bar is htmx-loaded on every page (GET /project/bar) so it's request-aware
// — it reads the `project` cookie the same way the scoped pages do.

import (
	"context"
	"net/http"

	"cloudbox.io/portal/internal/kube"
)

// projectList is the selectable set: the default project (demo) always first,
// then any labelled project namespaces. Best-effort — a list error just yields
// the default, so the bar always renders.
func (s *Server) projectList(ctx context.Context) []string {
	out := []string{kube.XRNamespace}
	seen := map[string]bool{kube.XRNamespace: true}
	if names, err := s.Kube.ListProjects(ctx); err == nil {
		for _, n := range names {
			if !seen[n] {
				seen[n] = true
				out = append(out, n)
			}
		}
	}
	return out
}

type projectBarData struct {
	Active   string
	Projects []string
	Default  string // the un-deletable default project
	Flash    flash
}

func (s *Server) barData(r *http.Request, fl flash) projectBarData {
	return projectBarData{
		Active:   s.activeProject(r),
		Projects: s.projectList(r.Context()),
		Default:  kube.XRNamespace,
		Flash:    fl,
	}
}

// HandleProjectBar renders the selector fragment htmx loads into the top bar.
func HandleProjectBar(s *Server, w http.ResponseWriter, r *http.Request) {
	s.render(w, "project-bar", s.barData(r, flash{}))
}

// HandleProjectSwitch sets the active-project cookie and reloads. Works with or
// without htmx: HX-Refresh for htmx, a plain redirect for a bare link click.
func HandleProjectSwitch(s *Server, w http.ResponseWriter, r *http.Request) {
	p := r.URL.Query().Get("set")
	if !kube.ValidName(p) {
		http.Error(w, "invalid project", http.StatusBadRequest)
		return
	}
	setProjectCookie(w, p)
	reload(w, r)
}

// HandleCreateProject provisions a project (namespace + tenant grant) and
// switches to it. On failure the bar re-renders with the error flash.
func HandleCreateProject(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	if err := s.Kube.CreateProject(r.Context(), name); err != nil {
		s.render(w, "project-bar", s.barData(r, errorFlash("Create failed: "+err.Error())))
		return
	}
	setProjectCookie(w, name)
	reload(w, r)
}

// HandleDeleteProject removes a project (cascading to its resources). The
// default project is protected; deleting the active one falls back to it.
func HandleDeleteProject(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if name == kube.XRNamespace {
		s.render(w, "project-bar", s.barData(r, errorFlash("The default project can't be deleted.")))
		return
	}
	if err := s.Kube.DeleteProject(r.Context(), name); err != nil {
		s.render(w, "project-bar", s.barData(r, errorFlash("Delete failed: "+err.Error())))
		return
	}
	if s.activeProject(r) == name {
		setProjectCookie(w, kube.XRNamespace)
	}
	reload(w, r)
}

func setProjectCookie(w http.ResponseWriter, p string) {
	http.SetCookie(w, &http.Cookie{Name: "project", Value: p, Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode})
}

// reload forces the browser to reload the current page so every project-scoped
// view re-fetches: HX-Refresh under htmx, a 303 back to the referring page for a
// plain navigation.
func reload(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("HX-Request") == "true" {
		w.Header().Set("HX-Refresh", "true")
		return
	}
	ref := r.Header.Get("Referer")
	if ref == "" {
		ref = "/"
	}
	http.Redirect(w, r, ref, http.StatusSeeOther)
}
