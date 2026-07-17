package web

// The templates and static assets live INSIDE the binary (go:embed is
// per-package, so they moved into internal/web together with this file).
// No CDN, no volume mounts — the offline rule is absolute.

import (
	"embed"
	"html/template"
	"net/http"
)

//go:embed templates/*.html
var templateFS embed.FS

// static/ holds htmx.min.js (vendored, v2.0.4) and the stylesheet.
//
//go:embed static
var staticFS embed.FS

// ParseTemplates registers the two functions the layout needs — the sidebar
// (built from the page registry) and the Grafana footer link — then parses
// everything embedded.
//
// It takes the *Server so the "nav" func can close over it and rebuild the
// sidebar from the live unlock cache on every request: the closure runs at
// render time, not parse time, so it sees the current cluster state (which
// pages have unlocked) rather than a stale snapshot. Callers must build the
// Server first and assign its Tmpl after — see main.go.
func ParseTemplates(s *Server) (*template.Template, error) {
	return template.New("portal").
		Funcs(template.FuncMap{
			"nav":        func() []navGroup { return navGroups(s.currentSnapshot()) },
			"grafanaURL": func() string { return s.GrafanaURL },
			"navicon":    navIcon,
			"icon":       icon,
		}).
		ParseFS(templateFS, "templates/*.html")
}

// Static serves the embedded assets; main mounts it under /static/.
func Static() http.Handler { return http.FileServerFS(staticFS) }
