package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"
)

// bombPNG crafts a syntactically valid PNG header (signature + IHDR chunk
// with a correct CRC) that *declares* a huge canvas. The whole file is 33
// bytes — but a naive image.Decode would try to allocate gigabytes for it.
func bombPNG(w, h uint32) []byte {
	var buf bytes.Buffer
	buf.Write([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a})
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], w)
	binary.BigEndian.PutUint32(ihdr[4:], h)
	ihdr[8] = 8 // bit depth
	ihdr[9] = 2 // color type: RGB
	chunk := append([]byte("IHDR"), ihdr...)
	binary.Write(&buf, binary.BigEndian, uint32(len(ihdr)))
	buf.Write(chunk)
	binary.Write(&buf, binary.BigEndian, crc32.ChecksumIEEE(chunk))
	return buf.Bytes()
}

func TestDecodeCheckedRejectsBombs(t *testing.T) {
	// 100000x100000 declared = 10 gigapixels; must be rejected from the
	// header alone, before any pixel is allocated.
	if _, _, err := decodeChecked(bombPNG(100000, 100000)); err == nil || !strings.Contains(err.Error(), "pixels") {
		t.Fatalf("decode bomb not rejected, err = %v", err)
	}
	// Garbage is rejected too.
	if _, _, err := decodeChecked([]byte("definitely not an image")); err == nil {
		t.Fatal("garbage bytes not rejected")
	}
	// A real, small image still decodes.
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 10, 10))); err != nil {
		t.Fatal(err)
	}
	if _, format, err := decodeChecked(buf.Bytes()); err != nil || format != "png" {
		t.Fatalf("valid image rejected: format=%q err=%v", format, err)
	}
}

func TestPermanentErrorClassification(t *testing.T) {
	if !isPermanent(permanent(errors.New("garbage image"))) {
		t.Error("wrapped error must classify as permanent")
	}
	if isPermanent(errors.New("connection refused")) {
		t.Error("plain error must stay transient (broker should retry it)")
	}
}

// solid returns a w×h image filled with one color, PNG-encoded and decoded
// again so the test exercises the same decode path production uses.
func solid(t *testing.T, w, h int, c color.RGBA) image.Image {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode: %v", err)
	}
	decoded, format, err := image.Decode(&buf)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if format != "png" {
		t.Fatalf("format = %q, want png", format)
	}
	return decoded
}

func TestThumbnailDimensions(t *testing.T) {
	cases := []struct {
		w, h         int
		wantW, wantH int
	}{
		{640, 480, 320, 240},  // landscape: halved
		{1000, 500, 320, 160}, // aspect ratio preserved
		{480, 640, 320, 426},  // portrait
		{100, 100, 100, 100},  // smaller than 320: never upscaled
		{320, 320, 320, 320},  // exactly 320: untouched
	}
	for _, c := range cases {
		got := thumbnail(solid(t, c.w, c.h, color.RGBA{R: 200, A: 255}), thumbWidth)
		if got.Bounds().Dx() != c.wantW || got.Bounds().Dy() != c.wantH {
			t.Errorf("thumbnail(%dx%d) = %dx%d, want %dx%d",
				c.w, c.h, got.Bounds().Dx(), got.Bounds().Dy(), c.wantW, c.wantH)
		}
	}
}

func TestDominantColor(t *testing.T) {
	if got := dominantColor(solid(t, 64, 64, color.RGBA{R: 255, A: 255})); got != "#ff0000" {
		t.Errorf("solid red: got %s", got)
	}
	if got := dominantColor(solid(t, 64, 64, color.RGBA{R: 12, G: 34, B: 56, A: 255})); got != "#0c2238" {
		t.Errorf("solid #0c2238: got %s", got)
	}
}

func TestDerivedKeys(t *testing.T) {
	thumb, meta := derivedKeys("originals/1700000000-cat.png")
	if thumb != "thumbs/1700000000-cat.png.jpg" {
		t.Errorf("thumb = %s", thumb)
	}
	if meta != "meta/1700000000-cat.png.json" {
		t.Errorf("meta = %s", meta)
	}
}
