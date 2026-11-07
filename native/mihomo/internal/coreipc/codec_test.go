package coreipc

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"testing"
	"time"

	A "clashpseudo/native/internal/appcontract"
)

func TestFrameFixedVectors(t *testing.T) {
	for _, tc := range []struct {
		kind       byte
		body, wire []byte
	}{
		{1, []byte("A"), []byte{0, 0, 0, 1, 1, 65}},
		{1, []byte{}, []byte{0, 0, 0, 0, 1}},
		{3, []byte("{}"), []byte{0, 0, 0, 2, 3, 123, 125}},
	} {
		var output bytes.Buffer
		w := Writer{Output: &output}
		if err := w.Write(tc.kind, tc.body); err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(output.Bytes(), tc.wire) {
			t.Fatalf("frame encoding mismatch: %x", output.Bytes())
		}
		frame, err := ReadFrame(bytes.NewReader(tc.wire))
		if err != nil || frame.Kind != tc.kind || !bytes.Equal(frame.Payload, tc.body) {
			t.Fatalf("frame decoding mismatch: %v %v", frame, err)
		}
	}
}
func TestFrameBoundariesAndMalformedInput(t *testing.T) {
	for _, size := range []int{0, A.CoreIpcFrameBytes, A.CoreIpcFrameBytes + 1} {
		var out bytes.Buffer
		w := Writer{Output: &out}
		err := w.Write(1, make([]byte, size))
		if (err != nil) != (size > A.CoreIpcFrameBytes) {
			t.Fatalf("size %d: %v", size, err)
		}
		if err == nil {
			if _, err = ReadFrame(&out); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, body := range [][]byte{{}, {0}, {0, 0, 0, 1}, {0, 0, 0, 1, 1}, {0, 0, 0, 0, 99}} {
		if _, err := ReadFrame(bytes.NewReader(body)); err == nil {
			t.Fatalf("accepted an interrupted frame: %x", body)
		}
	}
	var header [5]byte
	binary.BigEndian.PutUint32(header[:4], A.CoreIpcFrameBytes+1)
	header[4] = 1
	if _, err := ReadFrame(bytes.NewReader(header[:])); err == nil {
		t.Fatal("accepted an oversized header")
	}
}
func partStream(t *testing.T, name string, declared int, body []byte, terminal bool) []byte {
	t.Helper()
	var out bytes.Buffer
	w := Writer{Output: &out}
	if err := w.JSON(4, map[string]any{"part": name, "bytes": declared}); err != nil {
		t.Fatal(err)
	}
	if err := w.Data(body); err != nil {
		t.Fatal(err)
	}
	if terminal {
		if err := w.JSON(3, map[string]bool{"complete": true}); err != nil {
			t.Fatal(err)
		}
	}
	return out.Bytes()
}
func TestPartsRequireCompleteTerminalAndExactBudgets(t *testing.T) {
	for _, name := range []string{A.CorePartRequest, A.CorePartConfig, A.CorePartOptions, A.CorePartTrust} {
		limit := PartLimits[name]
		for _, size := range []int{0, limit, limit + 1} {
			body := bytes.Repeat([]byte("A"), size)
			stream := partStream(t, name, size, body, true)
			parts, err := ReadParts(bytes.NewReader(stream))
			if size > limit {
				if err == nil {
					t.Fatalf("accepted oversized part %s", name)
				}
				continue
			}
			if err != nil || !bytes.Equal(parts[name], body) {
				t.Fatalf("part %s size %d: %v", name, size, err)
			}
		}
	}
	for _, stream := range [][]byte{
		partStream(t, "request", 2, []byte("A"), true), partStream(t, "request", 0, []byte("A"), true),
		partStream(t, "request", 1, []byte("A"), false), partStream(t, "request", 1, []byte{255}, true),
		partStream(t, "other", 0, nil, true), partStream(t, "choices", 2, []byte("{}"), true),
	} {
		if _, err := ReadParts(bytes.NewReader(stream)); err == nil {
			t.Fatal("accepted incomplete or invalid input")
		}
	}
	var out bytes.Buffer
	w := Writer{Output: &out}
	_ = w.JSON(4, map[string]any{"part": "request", "bytes": 0})
	_ = w.JSON(4, map[string]any{"part": "request", "bytes": 0})
	_ = w.JSON(3, map[string]bool{"complete": true})
	if _, err := ReadParts(&out); err == nil {
		t.Fatal("accepted a duplicate part")
	}
}
func TestRecordStreamExceedsSingleFrameBudgetAndBackpressures(t *testing.T) {
	r, w := io.Pipe()
	done := make(chan error, 1)
	go func() {
		writer := Writer{Output: w}
		body := bytes.Repeat([]byte("A"), 1<<20)
		for i := 0; i < 17; i++ {
			if err := writer.Write(2, body); err != nil {
				done <- err
				return
			}
		}
		done <- writer.JSON(3, Terminal{Complete: true, RecordCount: writer.Count, Exited: true})
		_ = w.Close()
	}()
	select {
	case err := <-done:
		t.Fatalf("no backpressure without a consumer: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	for i := 0; i < 17; i++ {
		frame, err := ReadFrame(r)
		if err != nil || frame.Kind != 2 || len(frame.Payload) != 1<<20 {
			t.Fatalf("record %d: %v", i, err)
		}
	}
	frame, err := ReadFrame(r)
	if err != nil || frame.Kind != 3 {
		t.Fatalf("terminal: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	_ = r.Close()
}
func TestWriterRejectsFramesAfterTerminalAndRetainsIOError(t *testing.T) {
	var out bytes.Buffer
	w := Writer{Output: &out}
	if err := w.JSON(3, Terminal{Complete: true, Exited: true}); err != nil {
		t.Fatal(err)
	}
	if err := w.Write(1, nil); err == nil {
		t.Fatal("writes were still accepted after the terminal")
	}
	r, p := io.Pipe()
	_ = r.Close()
	w = Writer{Output: p}
	err := w.Write(1, []byte("A"))
	if !errors.Is(err, io.ErrClosedPipe) {
		var failure *Error
		if !errors.As(err, &failure) || failure.Message != io.ErrClosedPipe.Error() {
			t.Fatalf("write error was lost: %v", err)
		}
	}
	_ = p.Close()
}
