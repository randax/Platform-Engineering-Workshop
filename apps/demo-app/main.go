// demo-app — the app-team golden path's sample workload.
//
// It exists to PROVE the wiring an Application composes: it reads the
// platform-injected DATABASE_URL and S3_* env, keeps a real visit counter in
// Postgres, and lists (and writes) objects in its S3 bucket. Deploy it via the
// console's "Build from a repo" and the page shows a live counter backed by the
// composed CNPG database and the composed RustFS bucket — the dependencies are
// not decoration, the app uses them.
//
// Resilient on purpose: if a dependency is still composing (or absent), the
// page renders with an inline "not ready" note instead of crashing — so it's
// legible while Crossplane converges.
package main

import (
	"context"
	"fmt"
	"html"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

func main() {
	port := envOr("PORT", "8080")
	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	http.HandleFunc("/", handle)
	log.Printf("demo-app listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handle(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	dbLine := visitCounter(ctx)
	bucketLine := bucketState(ctx)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, page, html.EscapeString(envOr("HOSTNAME", "demo-app")), dbLine, bucketLine)
}

// visitCounter increments and reads a real row in the composed Postgres, via
// the injected DATABASE_URL. Any failure is returned as a human line.
func visitCounter(ctx context.Context) string {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return `<span class="warn">DATABASE_URL not set — no database wired.</span>`
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return notReady("database", err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS visits (id serial PRIMARY KEY, at timestamptz DEFAULT now())`); err != nil {
		return notReady("database", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO visits DEFAULT VALUES`); err != nil {
		return notReady("database", err)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM visits`).Scan(&n); err != nil {
		return notReady("database", err)
	}
	return fmt.Sprintf(`You are visitor <b>#%d</b> — counted in the composed Postgres (<code>%s</code>).`, n, host(dsn))
}

// bucketState lists the composed S3 bucket and writes a marker object, via the
// injected S3_* env — proving read+write against the composed RustFS bucket.
func bucketState(ctx context.Context) string {
	endpoint := os.Getenv("S3_ENDPOINT")
	bucket := os.Getenv("S3_BUCKET")
	if endpoint == "" || bucket == "" {
		return `<span class="warn">S3_ENDPOINT / S3_BUCKET not set — no bucket wired.</span>`
	}
	ep := strings.TrimPrefix(strings.TrimPrefix(endpoint, "http://"), "https://")
	cli, err := minio.New(ep, &minio.Options{
		Creds:  credentials.NewStaticV4(os.Getenv("S3_ACCESS_KEY"), os.Getenv("S3_SECRET_KEY"), ""),
		Secure: strings.HasPrefix(endpoint, "https://"),
	})
	if err != nil {
		return notReady("bucket", err)
	}
	// Write a marker so the listing is never empty (best-effort).
	body := strings.NewReader("hello from demo-app at " + time.Now().UTC().Format(time.RFC3339))
	_, _ = cli.PutObject(ctx, bucket, "demo-app/last-visit.txt", body, body.Size(), minio.PutObjectOptions{ContentType: "text/plain"})

	var keys []string
	for obj := range cli.ListObjects(ctx, bucket, minio.ListObjectsOptions{Recursive: true}) {
		if obj.Err != nil {
			return notReady("bucket", obj.Err)
		}
		keys = append(keys, html.EscapeString(obj.Key))
		if len(keys) >= 10 {
			break
		}
	}
	list := "(empty)"
	if len(keys) > 0 {
		list = "<code>" + strings.Join(keys, "</code>, <code>") + "</code>"
	}
	return fmt.Sprintf(`Bucket <code>%s</code> on the composed RustFS — objects: %s`, html.EscapeString(bucket), list)
}

func notReady(dep string, err error) string {
	return fmt.Sprintf(`<span class="warn">%s not ready yet (%s) — Crossplane may still be composing it.</span>`,
		dep, html.EscapeString(truncate(err.Error(), 120)))
}

// host pulls a display host out of a postgres DSN without leaking the password.
func host(dsn string) string {
	if i := strings.Index(dsn, "@"); i >= 0 {
		rest := dsn[i+1:]
		if j := strings.IndexAny(rest, ":/"); j >= 0 {
			return rest[:j]
		}
		return rest
	}
	return "postgres"
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

const page = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>demo-app</title>
<style>
 body{font-family:system-ui,-apple-system,sans-serif;max-width:44rem;margin:4rem auto;padding:0 1.5rem;line-height:1.6;color:#171e2c}
 h1{letter-spacing:-.02em} code{background:#f2f5f9;padding:.05rem .3rem;border-radius:4px;font-size:.9em}
 .card{border:1px solid #e4e8ef;border-radius:11px;padding:1rem 1.25rem;margin:1rem 0;box-shadow:0 1px 3px rgba(15,22,41,.05)}
 .warn{color:#a85906} .tag{font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;color:#5b6472;font-weight:600}
</style></head><body>
<span class="tag">Cloudbox · app-team golden path</span>
<h1>demo-app <small style="color:#5b6472;font-weight:400">— %s</small></h1>
<p>Deployed from source: your code, built in-cluster and wired to its dependencies by the platform.</p>
<div class="card"><div class="tag">Database</div><p>%s</p></div>
<div class="card"><div class="tag">Object storage</div><p>%s</p></div>
<p style="color:#5b6472"><small>Refresh to increment the counter. Change the code, push, and hit <b>Redeploy</b> in the console to roll a new version.</small></p>
</body></html>`
