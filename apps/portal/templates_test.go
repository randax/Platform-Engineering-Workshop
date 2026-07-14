package main

import (
	"html/template"
	"io"
	"testing"
)

// Executes every page template with representative data, so a typo in a
// template or a renamed struct field fails `go test` instead of a live page.
func TestTemplatesRender(t *testing.T) {
	tmpl, err := template.ParseFS(templateFS, "templates/*.html")
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}

	app := argoApp{}
	app.Metadata.Name = "gitea"
	app.Status.Sync.Status = "Synced"
	app.Status.Health.Status = "Healthy"

	db := workshopDB{}
	db.Metadata.Name = "my-db"
	db.Spec.Size = "small"
	db.Spec.StorageGB = 1

	pages := map[string]any{
		"overview": map[string]any{
			"Apps":    []argoApp{app},
			"Summary": clusterSummary{Namespaces: 3, Pods: 10, PodsRunning: 9},
		},
		"databases": databasesData{
			Clusters:  []cnpgCluster{{}},
			Databases: []workshopDB{db},
			Namespace: xrNamespace,
		},
		"db-list": databasesData{Flash: "hello"},
		"gallery": galleryData{Items: []galleryItem{
			{Key: "originals/1-cat.png", Name: "1-cat.png", URL: "http://x", ThumbURL: "http://y",
				Meta: &imageMeta{Width: 640, Height: 480, Format: "png", Bytes: 1234, DominantColor: "#aabbcc"}},
			{Key: "originals/2-dog.png", Name: "2-dog.png"}, // not yet processed
		}},
		"gallery-grid": galleryData{},
		"services":     []knativeService{{}},
		"error":        "boom",
	}
	for name, data := range pages {
		if err := tmpl.ExecuteTemplate(io.Discard, name, data); err != nil {
			t.Errorf("rendering %q: %v", name, err)
		}
	}
}
