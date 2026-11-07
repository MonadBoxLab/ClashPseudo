package engine

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"clashpseudo/native/internal/logstream"
	ML "github.com/metacubex/mihomo/log"
)

func publishLogBarrier(t *testing.T, text string) {
	t.Helper()
	subscription := ML.Subscribe()
	// UnSubscribe waits for the upstream broadcast lock; all live subscriptions have received this event before it returns.
	defer ML.UnSubscribe(subscription)
	ML.Infoln("%s", text)
	timeout := time.NewTimer(2 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case event := <-subscription:
			if event.Payload == text {
				return
			}
		case <-timeout.C:
			t.Fatal("upstream did not publish the log barrier")
		}
	}
}
func TestLogsKeepOriginalMessagesAndConsumeTransportQueue(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	queue := e.LogQueue()
	if err := e.Prepare(t.TempDir(), []byte("rules: ['MATCH,DIRECT']\n"), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if e.LogQueue() != queue {
		t.Fatal("Prepare replaced the subscription created before loading")
	}
	const address = "connect https://user:pass@example.test/path?token=abc"
	const password = "password=hunter2 retrying"
	long := strings.Repeat("日", 16384)
	ML.Infoln(address)
	ML.Warnln(password)
	ML.Errorln("%s", long)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	seen := map[string]string{}
	var previous int64
	for {
		entry, err := queue.Next(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if entry.Seq <= previous {
			t.Fatal("Seq did not increase", entry.Seq, previous)
		}
		previous = entry.Seq
		seen[entry.Text] = entry.Level
		if entry.Text == long {
			break
		}
	}
	if seen[address] != "info" || seen[password] != "warning" || seen[long] != "error" {
		t.Fatal("original log text or level changed")
	}
	next, _ := queue.Watermark()
	if next != previous {
		t.Fatal(next, previous)
	}
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	closedSeq, closedDropped := queue.Watermark()
	publishLogBarrier(t, "unrelated event after stop")
	for {
		entry, err := queue.Next(context.Background())
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil || entry.Text == "unrelated event after stop" {
			t.Fatal("closed queue still received an event", entry, err)
		}
	}
	if seq, dropped := queue.Watermark(); seq != closedSeq || dropped != closedDropped {
		t.Fatal("queue watermark changed after closing", seq, dropped, closedSeq, closedDropped)
	}
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
}
func TestFailedPreparationKeepsItsCapturedQueueUntilStop(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var previous Engine
	old := previous.LogQueue()
	publishLogBarrier(t, "previous session sentinel")
	if err := previous.Stop(); err != nil {
		t.Fatal(err)
	}
	var e Engine
	queue := e.LogQueue()
	defer requireStop(t, &e)
	if queue == old {
		t.Fatal("new Engine reused the old queue")
	}
	if err := e.Prepare(t.TempDir(), []byte("rules: [invalid"), "rule", func(int) bool { return true }); err == nil {
		t.Fatal("invalid configuration was accepted")
	}
	if e.LogQueue() != queue {
		t.Fatal("failed Prepare replaced the current queue")
	}
	publishLogBarrier(t, "failure session sentinel")
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	entries := []logstream.LogEntry{}
	for {
		entry, err := queue.Next(context.Background())
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		entries = append(entries, entry)
	}
	found := false
	for _, entry := range entries {
		if entry.Text == "previous session sentinel" {
			t.Fatal("old queue contents reached the new Engine")
		}
		if entry.Text == "failure session sentinel" {
			found = true
		}
	}
	if !found {
		t.Fatal("current queue lost an actual event")
	}
	publishLogBarrier(t, "unrelated event after failure")
	if _, err := queue.Next(context.Background()); !errors.Is(err, io.EOF) {
		t.Fatal(err)
	}
}
func TestEngineLogStreamPreservesConsumerErrorAndDoesNotRetainConsumedEntries(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	queue := e.LogQueue()
	defer queue.Close()
	publishLogBarrier(t, "consumer sentinel")
	original := errors.New("consumer原始错误")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := e.StreamLogs(ctx, func(entry logstream.LogEntry) error {
		if entry.Text != "consumer sentinel" {
			t.Fatal(entry)
		}
		return original
	}); err != original {
		t.Fatal(err)
	}
	queue.Close()
	if _, err := queue.Next(context.Background()); !errors.Is(err, io.EOF) {
		t.Fatal("a second history was retained after consumption", err)
	}
}
