package main

// Gallery backing store: the capstone pipeline's `images` bucket on RustFS.
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
	"log"
	"sort"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"go.opentelemetry.io/otel"
)

type s3Client struct {
	api     *minio.Client // cluster-internal endpoint, used for ListObjects/GetObject
	presign *minio.Client // browser-reachable endpoint, used only to sign URLs
	bucket  string
}

func newS3Client() (*s3Client, error) {
	endpoint := envOr("S3_ENDPOINT", "rustfs-svc.rustfs.svc.cluster.local:9000")
	public := envOr("S3_PUBLIC_ENDPOINT", "localhost:30900") // RustFS NodePort
	creds := credentials.NewStaticV4(
		envOr("S3_ACCESS_KEY", "cloudbox"),
		envOr("S3_SECRET_KEY", "cloudbox123"),
		"",
	)

	api, err := minio.New(trimScheme(endpoint), &minio.Options{Creds: creds, Secure: false})
	if err != nil {
		return nil, err
	}
	pre, err := minio.New(trimScheme(public), &minio.Options{Creds: creds, Secure: false})
	if err != nil {
		return nil, err
	}
	return &s3Client{api: api, presign: pre, bucket: envOr("S3_BUCKET", "images")}, nil
}

func trimScheme(ep string) string {
	ep = strings.TrimPrefix(ep, "http://")
	return strings.TrimPrefix(ep, "https://")
}

// galleryItem pairs an original with the artifacts the resizer derives from
// it. ThumbURL and Meta stay empty until the pipeline has processed the image
// — refreshing the gallery while that happens is half the fun.
type galleryItem struct {
	Key      string     // originals/<timestamp>-<name>
	Name     string     // <timestamp>-<name>, the shared base key
	URL      string     // presigned GET for the original
	ThumbURL string     // presigned GET for thumbs/<base>.jpg, if it exists
	Meta     *imageMeta // parsed meta/<base>.json, if it exists
}

// imageMeta mirrors the JSON the resizer writes to meta/.
type imageMeta struct {
	Width         int    `json:"width"`
	Height        int    `json:"height"`
	Format        string `json:"format"`
	Bytes         int64  `json:"bytes"`
	DominantColor string `json:"dominantColor"`
}

// HumanBytes renders the original's size the way a file manager would.
func (m imageMeta) HumanBytes() string {
	switch {
	case m.Bytes >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(m.Bytes)/(1<<20))
	case m.Bytes >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(m.Bytes)/(1<<10))
	default:
		return fmt.Sprintf("%d B", m.Bytes)
	}
}

const presignTTL = 15 * time.Minute

// listGallery lists originals/ and joins them with thumbs/ and meta/ by base
// key. Three prefix listings + one tiny GET per meta file. The manual span
// makes the S3 round-trips visible as one block inside the page's trace.
func (s *s3Client) listGallery(ctx context.Context) ([]galleryItem, error) {
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

	var items []galleryItem
	for obj := range s.api.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: "originals/", Recursive: true}) {
		if obj.Err != nil {
			return nil, obj.Err
		}
		base := strings.TrimPrefix(obj.Key, "originals/")
		item := galleryItem{Key: obj.Key, Name: base}

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

// countPrefix counts objects under a prefix — the workshop checklist uses it
// to answer "has the resizer produced a thumbnail yet?".
func (s *s3Client) countPrefix(ctx context.Context, prefix string) (int, error) {
	n := 0
	for obj := range s.api.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if obj.Err != nil {
			return n, obj.Err
		}
		n++
	}
	return n, nil
}

func (s *s3Client) readMeta(ctx context.Context, key string) *imageMeta {
	obj, err := s.api.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil
	}
	defer obj.Close()
	var m imageMeta
	if err := json.NewDecoder(obj).Decode(&m); err != nil {
		return nil
	}
	return &m
}
