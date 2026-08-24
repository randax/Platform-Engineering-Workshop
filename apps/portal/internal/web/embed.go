package web

import (
	"embed"
	"html/template"
	"net/http"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

func ParseTemplates(s *Server) (*template.Template, error) {
	return template.New("portal").
		Funcs(template.FuncMap{
			"nav":        func() []navGroup { return navGroups(s.currentSnapshot()) },
			"grafanaURL": func() string { return s.GrafanaURL },
			"navicon":    navIcon,
			"icon":       icon,
			"truncate": func(s string, max int) string {
				if len(s) > max {
					return s[:max] + "..."
				}
				return s
			},
		}).
		ParseFS(templateFS, "templates/*.html")
}

func Static() http.Handler { return http.FileServerFS(staticFS) }
