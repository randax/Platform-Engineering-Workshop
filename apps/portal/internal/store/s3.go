package store

// Package store is the gallery's backing store: the capstone pipeline's
// `images` bucket on RustFS.
//
// One subtlety worth understanding: presigned URLs embed the *host* they were
// signed for. The portal talks to RustFS on its cluster-internal Service
// address, but your browser can only reach RustFS through the NodePort
// (localhost:30900). So we keep two minio clients with the same credentials —
// one for API calls from inside the cluster, one only used to sign URLs the
// browser will follow.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"go.opentelemetry.io/otel"
)

type Client struct {
	api     *minio.Client // cluster-internal endpoint, used for ListObjects/GetObject
	presign *minio.Client // browser-reachable endpoint, used only to sign URLs
	bucket  string
}

// Config carries the S3 settings in from main — this package never reads
// the environment itself.
type Config struct {
	Endpoint       string // cluster-internal S3 API
	PublicEndpoint string // what the browser can reach (presigned URLs)
	AccessKey      string
	SecretKey      string
	Bucket         string
}

func New(cfg Config) (*Client, error) {
	creds := credentials.NewStaticV4(cfg.AccessKey, cfg.SecretKey, "")
	api, err := minio.New(trimScheme(cfg.Endpoint), &minio.Options{Creds: creds, Secure: false})
	if err != nil {
		return nil, err
	}
	pre, err := minio.New(trimScheme(cfg.PublicEndpoint), &minio.Options{Creds: creds, Secure: false})
	if err != nil {
		return nil, err
	}
	return &Client{api: api, presign: pre, bucket: cfg.Bucket}, nil
}

func trimScheme(ep string) string {
	ep = strings.TrimPrefix(ep, "http://")
	return strings.TrimPrefix(ep, "https://")
}

// Item pairs an original with the artifacts the resizer derives from
// it. ThumbURL and Meta stay empty until the pipeline has processed the image
// — refreshing the gallery while that happens is half the fun.
type Item struct {
	Key      string     // originals/<timestamp>-<name>
	Name     string     // <timestamp>-<name>, the shared base key
	URL      string     // presigned GET for the original
	ThumbURL string     // presigned GET for thumbs/<base>.jpg, if it exists
	Meta     *ImageMeta // parsed meta/<base>.json, if it exists
}

// ImageMeta mirrors the JSON the resizer writes to meta/.
type ImageMeta struct {
	Width         int    `json:"width"`
	Height        int    `json:"height"`
	Format        string `json:"format"`
	Bytes         int64  `json:"bytes"`
	DominantColor string `json:"dominantColor"`
}

// HumanBytes renders the original's size the way a file manager would.
func (m ImageMeta) HumanBytes() string { return humanBytes(m.Bytes) }

// humanBytes formats a byte count the way a file manager would — shared by
// ImageMeta (the resizer's analysis) and ObjectInfo (the bucket browser).
func humanBytes(b int64) string {
	switch {
	case b >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(b)/(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(b)/(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
}

const presignTTL = 15 * time.Minute

// BucketInfo is one row of the bucket browser: the name and when it was
// created. This is the whole payload of an S3 ListBuckets call — the same API
// the attendee stood up in module 03.
type BucketInfo struct {
	Name    string
	Created time.Time
}

// ObjectInfo is one object inside a bucket. Deliberately just the three columns
// a browser needs — key, size, mtime — not minio's full metadata struct, so the
// web layer never imports the S3 client.
type ObjectInfo struct {
	Key          string
	Size         int64
	LastModified time.Time
}

// HumanBytes renders the object's size the way a file manager would.
func (o ObjectInfo) HumanBytes() string { return humanBytes(o.Size) }

// ListBuckets returns every bucket on the API endpoint — the read half of the
// module-03 "you have object storage now" win. One S3 round-trip, no prefixes.
func (s *Client) ListBuckets(ctx context.Context) ([]BucketInfo, error) {
	found, err := s.api.ListBuckets(ctx)
	if err != nil {
		return nil, err
	}
	buckets := make([]BucketInfo, 0, len(found))
	for _, b := range found {
		buckets = append(buckets, BucketInfo{Name: b.Name, Created: b.CreationDate})
	}
	return buckets, nil
}

// CreateBucket makes a new bucket on the API endpoint — the write half of the
// module-03 win, from the console. Idempotent-ish: minio returns an error if it
// already exists, which the handler surfaces as a friendly flash.
func (s *Client) CreateBucket(ctx context.Context, name string) error {
	return s.api.MakeBucket(ctx, name, minio.MakeBucketOptions{})
}

// PutObject uploads one object. size may be -1 (unknown) — minio then streams
// with a multipart upload; for the small files this console handles, passing the
// known size from the multipart header is the common path.
func (s *Client) PutObject(ctx context.Context, bucket, key string, r io.Reader, size int64, contentType string) error {
	_, err := s.api.PutObject(ctx, bucket, key, r, size, minio.PutObjectOptions{ContentType: contentType})
	return err
}

// DeleteObject removes one object from a bucket.
func (s *Client) DeleteObject(ctx context.Context, bucket, key string) error {
	return s.api.RemoveObject(ctx, bucket, key, minio.RemoveObjectOptions{})
}

// DeleteBucket removes an (empty) bucket. RustFS/minio refuse a non-empty
// bucket, so the handler tells the user to empty it first — the same guardrail
// real S3 has.
func (s *Client) DeleteBucket(ctx context.Context, name string) error {
	return s.api.RemoveBucket(ctx, name)
}

// ListObjectsIn lists a bucket's objects, capped at max. The cap matters: a
// bucket can hold millions of keys, and ListObjects streams them one by one —
// without a ceiling a fat bucket would hang the page rendering it. The manual
// span makes the S3 walk visible as one block inside the request's trace.
func (s *Client) ListObjectsIn(ctx context.Context, bucket string, max int) ([]ObjectInfo, error) {
	ctx, span := otel.Tracer("portal").Start(ctx, "s3 list objects")
	defer span.End()
	// Cancel on return so an early break (len >= max) tells minio's listing
	// goroutine to stop — otherwise it blocks trying to send the next key and
	// leaks until the request context ends.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var objects []ObjectInfo
	for obj := range s.api.ListObjects(ctx, bucket, minio.ListObjectsOptions{Recursive: true}) {
		if obj.Err != nil {
			return nil, obj.Err
		}
		objects = append(objects, ObjectInfo{Key: obj.Key, Size: obj.Size, LastModified: obj.LastModified})
		if len(objects) >= max {
			break // stop draining the channel — the deferred cancel unwinds the listing
		}
	}
	return objects, nil
}

// PresignGet mints a time-limited download URL for one object, signed by the
// browser-facing endpoint (see the package doc: presigned URLs embed the host
// they were signed for, and only the presign client knows one your browser can
// reach). The attendee gets a working link with zero AWS and zero credentials.
func (s *Client) PresignGet(ctx context.Context, bucket, key string) (string, error) {
	u, err := s.presign.PresignedGetObject(ctx, bucket, key, presignTTL, nil)
	if err != nil {
		return "", err
	}
	return u.String(), nil
}

// ListGallery lists originals/ and joins them with thumbs/ and meta/ by base
// key. Three prefix listings + one tiny GET per meta file. The manual span
// makes the S3 round-trips visible as one block inside the page's trace.
func (s *Client) ListGallery(ctx context.Context) ([]Item, error) {
	ctx, span := otel.Tracer("portal").Start(ctx, "s3 list gallery")
	defer span.End()
	exists := func(prefix string) (map[string]bool, error) {
		m := map[string]bool{}
		for obj := range s.api.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
			if obj.Err != nil {
				return nil, obj.Err
			}
			m[obj.Key] = true
		}
		return m, nil
	}
	thumbs, err := exists("thumbs/")
	if err != nil {
		return nil, err
	}
	metas, err := exists("meta/")
	if err != nil {
		return nil, err
	}

	var items []Item
	for obj := range s.api.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: "originals/", Recursive: true}) {
		if obj.Err != nil {
			return nil, obj.Err
		}
		base := strings.TrimPrefix(obj.Key, "originals/")
		item := Item{Key: obj.Key, Name: base}

		if u, err := s.presign.PresignedGetObject(ctx, s.bucket, obj.Key, presignTTL, nil); err == nil {
			item.URL = u.String()
		} else {
			log.Printf("presigning %s: %v", obj.Key, err)
		}
		if thumbKey := "thumbs/" + base + ".jpg"; thumbs[thumbKey] {
			if u, err := s.presign.PresignedGetObject(ctx, s.bucket, thumbKey, presignTTL, nil); err == nil {
				item.ThumbURL = u.String()
			} else {
				log.Printf("presigning %s: %v", thumbKey, err)
			}
		}
		if metaKey := "meta/" + base + ".json"; metas[metaKey] {
			item.Meta = s.readMeta(ctx, metaKey)
		}
		items = append(items, item)
	}

	// Keys start with a unix timestamp, so newest-first is a string sort.
	sort.Slice(items, func(i, j int) bool { return items[i].Name > items[j].Name })
	if len(items) > 100 {
		items = items[:100]
	}
	return items, nil
}

// CountPrefix counts objects under a prefix — the workshop checklist uses it
// to answer "has the resizer produced a thumbnail yet?".
func (s *Client) CountPrefix(ctx context.Context, prefix string) (int, error) {
	n := 0
	for obj := range s.api.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if obj.Err != nil {
			return n, obj.Err
		}
		n++
	}
	return n, nil
}

func (s *Client) readMeta(ctx context.Context, key string) *ImageMeta {
	obj, err := s.api.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil
	}
	defer obj.Close()
	var m ImageMeta
	if err := json.NewDecoder(obj).Decode(&m); err != nil {
		return nil
	}
	return &m
}
