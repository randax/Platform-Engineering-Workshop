package web

// The Buckets page: a read-only S3 object browser over RustFS. There's no
// magic here — it's the module-03 payoff seen from outside. ListBuckets and
// ListObjects are the same S3 API the attendee stood up in module 03, and the
// "Download" link is a presigned URL signed by the browser-facing endpoint, so
// the file downloads straight from RustFS with zero AWS and zero credentials.

import (
	"context"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"regexp"
	"time"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
	"cloudbox.io/portal/internal/store"
)

// s3Timeout bounds an S3 read so a slow/wedged RustFS can't hang the page:
// minio-go only respects the context, and the HTTP server has no WriteTimeout
// (the Invoke proxy needs a long one). Generous for a lab list of ≤200 objects
// (adversarial review I1).
func s3Ctx(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), 15*time.Second)
}

func init() {
	register(Page{
		// Weight 60 sits right after Databases (56) in the Services section.
		Weight:     60,
		NavSection: "Services",
		NavTitle:   "Buckets",
		Path:       "/buckets",
		Handler:    handleBuckets,
		// Data (module 03): the S3 API only answers once RustFS is deployed and
		// Healthy — before that there are no buckets to browse, only errors.
		Unlock:     func(s kube.Snapshot) bool { _, h := s.AppHealthy("rustfs"); return h },
		LockedHint: "Complete Module 03 · Data",
		Teaser:     "Browse your object storage and hand out presigned download links — create buckets, upload and delete objects, all on the S3 API you stood up, no AWS required.",
		// Mutating routes. No CSRF token — single-user disposable lab. These are
		// pure S3 (minio-go → RustFS); no Kubernetes RBAC is involved.
		Extra: []Route{
			{"GET /buckets/objects", handleBucketObjects}, // htmx-loaded object list
			{"POST /buckets", handleCreateBucket},
			{"DELETE /buckets/{bucket}", handleDeleteBucket},
			{"POST /buckets/{bucket}/upload", handleUploadObject},
			{"DELETE /buckets/{bucket}/objects/{key...}", handleDeleteObject},
		},
	})
}

// bucketName is the S3 naming rule we enforce client-side for a friendly error:
// lowercase DNS-ish, 3–63 chars, no leading/trailing hyphen.
var bucketName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`)

// maxObjects caps a single object listing. A bucket can hold millions of keys;
// this browser is a teaching aid, not a file manager, so 200 rows is plenty and
// keeps a fat bucket from hanging the page.
const maxObjects = 200

// bucketStore is the slice of object storage this page consumes — a
// consumer-side interface, so the rendering is testable with an in-memory fake
// instead of a real S3. *store.Client satisfies it in production.
type bucketStore interface {
	ListBuckets(ctx context.Context) ([]store.BucketInfo, error)
	ListObjectsIn(ctx context.Context, bucket string, max int) ([]store.ObjectInfo, error)
	PresignGet(ctx context.Context, bucket, key string) (string, error)
}

// objectRow is one object plus the presigned link the browser follows to
// download it. The URL is minted at render time — presigned GETs are cheap and
// short-lived (15 min), so there's nothing to cache or invalidate.
type objectRow struct {
	store.ObjectInfo
	DownloadURL string
}

// objectsData backs the object-list fragment for one selected bucket.
type objectsData struct {
	Bucket  string
	Objects []objectRow
	Flash   flash
}

// bucketsData backs the full page: the bucket list, plus the selected bucket's
// objects when one is chosen (via ?b= on load). Objects.Bucket == "" means no
// selection yet — the fragment slot shows a prompt instead.
type bucketsData struct {
	Buckets []store.BucketInfo
	Objects objectsData
	Flash   flash

	// Monitoring — RustFS exposes no Prometheus metrics, so this is the generic
	// per-namespace signal (kubeletstats CPU/mem), the same fallback the
	// component-detail page uses. Populated only on the full page, only when
	// observability is collecting.
	Telemetry bool
	CPUSpark  template.HTML
	CPUNow    string
	MemSpark  template.HTML
	MemNow    string
}

// bucketObjects lists one bucket's objects and pairs each with a presigned
// download URL. Kept separate from the HTTP handler so a fake bucketStore can
// drive it in tests.
func bucketObjects(ctx context.Context, st bucketStore, bucket string, fl flash) (objectsData, error) {
	objs, err := st.ListObjectsIn(ctx, bucket, maxObjects)
	if err != nil {
		return objectsData{}, err
	}
	rows := make([]objectRow, 0, len(objs))
	for _, o := range objs {
		row := objectRow{ObjectInfo: o}
		// Sign each object with the browser-facing endpoint. A signing failure
		// only costs that one download link, so log it and keep the row.
		if u, err := st.PresignGet(ctx, bucket, o.Key); err == nil {
			row.DownloadURL = u
		} else {
			log.Printf("presigning %s/%s: %v", bucket, o.Key, err)
		}
		rows = append(rows, row)
	}
	return objectsData{Bucket: bucket, Objects: rows, Flash: fl}, nil
}

// bucketsPage builds the full-page payload: always the bucket list, plus the
// selected bucket's objects when ?b= names one (so the selection is
// bookmarkable and works without JavaScript).
func bucketsPage(ctx context.Context, st bucketStore, selected string) (bucketsData, error) {
	buckets, err := st.ListBuckets(ctx)
	if err != nil {
		return bucketsData{}, err
	}
	data := bucketsData{Buckets: buckets}
	if selected != "" {
		// A failure listing the selected bucket must not take down the whole
		// page — keep the bucket list and show the error in the objects panel,
		// matching the htmx fragment's degrade-in-place behaviour.
		if objs, err := bucketObjects(ctx, st, selected, flash{}); err != nil {
			data.Objects = objectsData{Bucket: selected, Flash: errorFlash("S3 error: " + err.Error())}
		} else {
			data.Objects = objs
		}
	}
	return data, nil
}

func handleBuckets(s *Server, w http.ResponseWriter, r *http.Request) {
	ctx, cancel := s3Ctx(r)
	defer cancel()
	data, err := bucketsPage(ctx, s.Store, r.URL.Query().Get("b"))
	if err != nil {
		s.renderError(w, err)
		return
	}
	// Monitoring: RustFS has no /metrics, so fall back to the generic namespace
	// resource signal (kubeletstats). Full page only, and only once
	// observability is collecting.
	if health, err := s.Kube.NamespaceWorkloads(r.Context()); err == nil && health["observability"].Ready > 0 && s.Prom != nil {
		data.Telemetry = true
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.NamespaceCPUQuery("rustfs")); len(v) > 0 {
			data.CPUSpark = metrics.Sparkline(v, "CPU usage")
			data.CPUNow = fmt.Sprintf("%.3f cores", v[len(v)-1])
		}
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.NamespaceMemQuery("rustfs")); len(v) > 0 {
			data.MemSpark = metrics.Sparkline(v, "memory working set")
			data.MemNow = humanBytes(v[len(v)-1])
		}
	}
	s.render(w, "buckets", data)
}

// handleBucketObjects serves the object-list fragment htmx swaps in when a
// bucket is clicked. Like the databases/gallery fragments, an error becomes a
// flash inside the fragment rather than a full error page, so the surrounding
// page stays intact.
func handleBucketObjects(s *Server, w http.ResponseWriter, r *http.Request) {
	bucket := r.URL.Query().Get("b")
	if bucket == "" {
		// No bucket named — don't fire an S3 call with an empty name (which
		// only errors and logs noise); ask for a selection instead.
		s.render(w, "bucket-objects", objectsData{Flash: errorFlash("No bucket selected")})
		return
	}
	ctx, cancel := s3Ctx(r)
	defer cancel()
	data, err := bucketObjects(ctx, s.Store, bucket, flash{})
	if err != nil {
		log.Printf("list objects in %s: %v", bucket, err)
		s.render(w, "bucket-objects", objectsData{Bucket: bucket, Flash: errorFlash("S3 error: " + err.Error())})
		return
	}
	s.render(w, "bucket-objects", data)
}

// renderBucketList re-lists the buckets and renders the list fragment with a
// flash — the response to create/delete-bucket, swapped into #bucket-list.
func (s *Server) renderBucketList(ctx context.Context, w http.ResponseWriter, fl flash) {
	buckets, err := s.Store.ListBuckets(ctx)
	if err != nil {
		s.render(w, "bucket-list", bucketsData{Flash: errorFlash("S3 error: " + err.Error())})
		return
	}
	s.render(w, "bucket-list", bucketsData{Buckets: buckets, Flash: fl})
}

// handleCreateBucket makes a bucket on the S3 API and re-renders the list.
func handleCreateBucket(s *Server, w http.ResponseWriter, r *http.Request) {
	ctx, cancel := s3Ctx(r)
	defer cancel()
	name := r.FormValue("name")
	fl := flash{Msg: "Created bucket " + name + "."}
	switch {
	case !bucketName.MatchString(name):
		fl = errorFlash("Invalid bucket name — 3–63 lowercase letters, digits or hyphens (no leading/trailing hyphen).")
	default:
		if err := s.Store.CreateBucket(ctx, name); err != nil {
			fl = errorFlash("Create failed: " + err.Error())
		}
	}
	s.renderBucketList(ctx, w, fl)
}

// handleDeleteBucket removes an empty bucket. RustFS refuses a non-empty one, so
// the flash tells the user to empty it first.
func handleDeleteBucket(s *Server, w http.ResponseWriter, r *http.Request) {
	ctx, cancel := s3Ctx(r)
	defer cancel()
	name := r.PathValue("bucket")
	fl := flash{Msg: "Deleted bucket " + name + "."}
	if err := s.Store.DeleteBucket(ctx, name); err != nil {
		fl = errorFlash("Delete failed — is the bucket empty? " + err.Error())
	}
	s.renderBucketList(ctx, w, fl)
}

// handleUploadObject streams one uploaded file into the bucket (key = filename)
// and re-renders that bucket's object list. maxUpload caps the multipart parse
// so a huge file can't exhaust memory in the lab pod.
const maxUpload = 32 << 20 // 32 MiB

func handleUploadObject(s *Server, w http.ResponseWriter, r *http.Request) {
	bucket := r.PathValue("bucket")
	if err := r.ParseMultipartForm(maxUpload); err != nil {
		s.render(w, "bucket-objects", objectsData{Bucket: bucket, Flash: errorFlash("Upload too large or malformed (max 32 MiB).")})
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		s.render(w, "bucket-objects", objectsData{Bucket: bucket, Flash: errorFlash("Pick a file to upload.")})
		return
	}
	defer file.Close()
	// Bound only the S3 work, not r.ParseMultipartForm above: the body is already
	// parsed to memory/tmp by here, so `file` is a local reader and the 15s
	// deadline covers the PutObject to RustFS + the re-list, never a client upload.
	ctx, cancel := s3Ctx(r)
	defer cancel()
	fl := flash{Msg: "Uploaded " + header.Filename + "."}
	if err := s.Store.PutObject(ctx, bucket, header.Filename, file, header.Size, header.Header.Get("Content-Type")); err != nil {
		fl = errorFlash("Upload failed: " + err.Error())
	}
	s.renderBucketObjectsAfter(ctx, w, bucket, fl)
}

// handleDeleteObject removes one object and re-renders the bucket's object list.
// The {key...} wildcard carries slashes, so keys like originals/1.png work.
func handleDeleteObject(s *Server, w http.ResponseWriter, r *http.Request) {
	ctx, cancel := s3Ctx(r)
	defer cancel()
	bucket, key := r.PathValue("bucket"), r.PathValue("key")
	fl := flash{Msg: "Deleted " + key + "."}
	if err := s.Store.DeleteObject(ctx, bucket, key); err != nil {
		fl = errorFlash("Delete failed: " + err.Error())
	}
	s.renderBucketObjectsAfter(ctx, w, bucket, fl)
}

// renderBucketObjectsAfter re-lists one bucket's objects with a flash — shared
// by upload and delete-object, both of which target #bucket-objects.
func (s *Server) renderBucketObjectsAfter(ctx context.Context, w http.ResponseWriter, bucket string, fl flash) {
	data, err := bucketObjects(ctx, s.Store, bucket, fl)
	if err != nil {
		s.render(w, "bucket-objects", objectsData{Bucket: bucket, Flash: errorFlash("S3 error: " + err.Error())})
		return
	}
	s.render(w, "bucket-objects", data)
}
