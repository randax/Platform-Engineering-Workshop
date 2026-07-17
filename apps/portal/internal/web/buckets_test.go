package web

// The Buckets page: pins the unlock gate (RustFS Healthy) and proves the
// object-list fragment renders keys and presigned download links from a fake
// store — no real S3 in the loop.

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/store"
)

// fakeBucketStore is an in-memory bucketStore: it hands back canned objects and
// a predictable presigned URL, so the fragment's rendering is testable without
// standing up RustFS.
type fakeBucketStore struct {
	buckets []store.BucketInfo
	objects map[string][]store.ObjectInfo
}

func (f fakeBucketStore) ListBuckets(context.Context) ([]store.BucketInfo, error) {
	return f.buckets, nil
}

func (f fakeBucketStore) ListObjectsIn(_ context.Context, bucket string, max int) ([]store.ObjectInfo, error) {
	objs := f.objects[bucket]
	if len(objs) > max {
		objs = objs[:max]
	}
	return objs, nil
}

func (f fakeBucketStore) PresignGet(_ context.Context, bucket, key string) (string, error) {
	// Mirror the shape of a real presigned URL: browser-facing host + a signature.
	return "http://localhost:30900/" + bucket + "/" + key + "?X-Amz-Signature=fake", nil
}

// TestBucketsUnlock pins the gate: locked from a bare cluster, unlocked the
// moment RustFS reports Healthy (mirrors unlock_test.go's approach).
func TestBucketsUnlock(t *testing.T) {
	if it, ok := findNavItem(navGroups(kube.Snapshot{}), "buckets"); !ok {
		t.Fatal("nav is missing the buckets page")
	} else if !it.Locked {
		t.Error("buckets must be locked when RustFS is not Healthy")
	}

	apps := map[string]kube.ArgoApp{"rustfs": fixtureApp("rustfs", "Healthy")}
	if it, ok := findNavItem(navGroups(kube.Snapshot{Apps: apps}), "buckets"); !ok {
		t.Fatal("nav is missing the buckets page")
	} else if it.Locked {
		t.Error("buckets must unlock once RustFS is Healthy")
	}
}

// TestBucketObjectsRender feeds a fake store through the same helper the handler
// uses, then renders the fragment and asserts the keys, humanized sizes, and
// presigned download links all land in the markup.
func TestBucketObjectsRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{})
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}

	st := fakeBucketStore{objects: map[string][]store.ObjectInfo{
		"images": {
			{Key: "originals/1-cat.png", Size: 250880, LastModified: time.Unix(1700000000, 0)},
			{Key: "thumbs/1-cat.png.jpg", Size: 4096, LastModified: time.Unix(1700000100, 0)},
		},
	}}

	data, err := bucketObjects(context.Background(), st, "images", flash{})
	if err != nil {
		t.Fatalf("bucketObjects: %v", err)
	}

	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "bucket-objects", data); err != nil {
		t.Fatalf("rendering bucket-objects: %v", err)
	}
	out := buf.String()

	for _, want := range []string{
		"originals/1-cat.png", // an object key
		"245 KB",              // 250880 bytes, humanized
		"http://localhost:30900/images/originals/1-cat.png?X-Amz-Signature=fake", // presigned link
		"Download ↗",                       // the download affordance
		`hx-post="/buckets/images/upload"`, // the upload form
		`hx-delete="/buckets/images/objects/originals/1-cat.png"`, // per-object delete (key with slash)
	} {
		if !strings.Contains(out, want) {
			t.Errorf("rendered fragment missing %q", want)
		}
	}
}

// TestBucketListRender proves the list fragment carries a Delete button per
// bucket (create/delete-bucket both target #bucket-list).
func TestBucketListRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{})
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}
	data := bucketsData{Buckets: []store.BucketInfo{{Name: "images", Created: time.Unix(1700000000, 0)}}}
	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "bucket-list", data); err != nil {
		t.Fatalf("rendering bucket-list: %v", err)
	}
	for _, want := range []string{`id="bucket-list"`, "images", `hx-delete="/buckets/images"`} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("bucket-list missing %q", want)
		}
	}
}

// TestBucketNameValidation pins the S3 naming rule the create handler enforces.
func TestBucketNameValidation(t *testing.T) {
	good := []string{"images", "my-bucket", "a1b2", "team-a-uploads"}
	bad := []string{"", "ab", "UP", "under_score", "-lead", "trail-", "dots.not.allowed", strings.Repeat("x", 64)}
	for _, n := range good {
		if !bucketName.MatchString(n) {
			t.Errorf("bucketName rejected valid %q", n)
		}
	}
	for _, n := range bad {
		if bucketName.MatchString(n) {
			t.Errorf("bucketName accepted invalid %q", n)
		}
	}
}
