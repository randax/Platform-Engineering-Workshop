package kube

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// DeleteProject must refuse to delete a namespace that isn't a console project
// (missing the project label) — the app-layer guard that stops a stray/typo'd
// name from deleting kube-system/argocd, since the portal's RBAC grant is
// cluster-wide namespace delete. This is also the first httptest-backed test of
// the kube.Client HTTP layer (adversarial review S1 + Tier-2 seam).
func TestDeleteProjectGuard(t *testing.T) {
	cases := []struct {
		name    string
		labels  string // the namespace's metadata.labels JSON
		wantDel bool   // should a DELETE actually be issued?
		wantErr bool
	}{
		{"team-a", `{"platform.cloudbox.io/project":"true"}`, true, false},
		{"kube-system", `{"kubernetes.io/metadata.name":"kube-system"}`, false, true},
		{"unlabelled", `{}`, false, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			deleted := false
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.Method {
				case http.MethodGet: // the guard reads the namespace's labels
					_, _ = w.Write([]byte(`{"metadata":{"labels":` + tc.labels + `}}`))
				case http.MethodDelete:
					deleted = true
					w.WriteHeader(http.StatusOK)
				}
			}))
			defer srv.Close()

			k := &Client{baseURL: srv.URL, client: srv.Client()}
			err := k.DeleteProject(context.Background(), tc.name)
			if (err != nil) != tc.wantErr {
				t.Fatalf("DeleteProject(%q): err = %v, wantErr %v", tc.name, err, tc.wantErr)
			}
			if deleted != tc.wantDel {
				t.Errorf("DeleteProject(%q): DELETE issued = %v, want %v", tc.name, deleted, tc.wantDel)
			}
		})
	}
}
