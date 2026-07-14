package web

// Easter eggs. Deadpan, deterministic, and self-contained — nothing here
// touches real routes' behaviour or the module-05 fault surface. They exist
// because a platform that pokes fun at Big Cloud should be willing to poke
// fun at itself. Find them by clicking, curling, or reading the source.

import "net/http"

// NotFound is the catch-all for unmatched GET paths. A serverless joke that
// still renders the full chrome, so nobody is actually stranded.
func NotFound(s *Server, w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusNotFound)
	s.render(w, "notfound", nil)
}

// Teapot: a hidden route, no nav entry. GET /teapot → 418.
func Teapot(_ *Server, w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusTeapot)
	w.Write([]byte("The console is a teapot. The cluster, however, is real.\n"))
}

// CloudHeaders stamps every response with the invoice, in header form.
func CloudHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Cloud-Provider", "you")
		h.Set("X-Egress-Fee", "0.00")
		h.Set("X-Region", "eu-laptop-1")
		next.ServeHTTP(w, r)
	})
}
