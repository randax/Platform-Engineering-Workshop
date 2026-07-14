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
func ParseTemplates(grafanaURL string) (*template.Template, error) {
	return template.New("portal").
		Funcs(template.FuncMap{
			"nav":        navGroups,
			"grafanaURL": func() string { return grafanaURL },
		}).
		ParseFS(templateFS, "templates/*.html")
}

// Static serves the embedded assets; main mounts it under /static/.
func Static() http.Handler { return http.FileServerFS(staticFS) }
