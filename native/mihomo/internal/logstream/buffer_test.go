package logstream

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
	"testing"
	"time"

	A "clashpseudo/native/internal/appcontract"
	ML "github.com/metacubex/mihomo/log"
)

func drain(t *testing.T, b *Buffer) []LogEntry {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	entries := []LogEntry{}
	for {
		entry, err := b.Next(ctx)
		if errors.Is(err, io.EOF) {
			return entries
		}
		if err != nil {
			t.Fatal(err)
		}
		entries = append(entries, entry)
	}
}
func TestLogsCloseWaitsForActualSubscriptionDrain(t *testing.T) {
	buffer := &Buffer{stop: make(chan struct{}), done: make(chan struct{})}
	subscription := make(chan ML.Event, 1)
	entered, release := make(chan struct{}), make(chan struct{})
	go buffer.collect(subscription, func() {
		close(entered)
		<-release
		subscription <- ML.Event{LogLevel: ML.ERROR, Payload: "actual final tail"}
		close(subscription)
	})
	closed := make(chan struct{})
	go func() { buffer.Close(); close(closed) }()
	<-entered
	select {
	case <-closed:
		close(release)
		t.Fatal("unsubscribe实际返回前Close已经返回")
	case <-time.After(2100 * time.Millisecond):
	}
	close(release)
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("unsubscribe返回后Close未结束")
	}
	entries := drain(t, buffer)
	if len(entries) != 1 || entries[0].Text != "actual final tail" {
		t.Fatal("Close丢失实际尾部日志")
	}
	buffer.Close()
}
func TestClosingLogsPreservesQueuedTailAndIsIdempotent(t *testing.T) {
	buffer := &Buffer{stop: make(chan struct{}), done: make(chan struct{})}
	subscription := make(chan ML.Event, 200)
	for index := 0; index < 150; index++ {
		subscription <- ML.Event{LogLevel: ML.INFO, Payload: strconv.Itoa(index)}
	}
	unsubscribed := make(chan struct{})
	go buffer.collect(subscription, func() { close(subscription); close(unsubscribed) })
	buffer.Close()
	buffer.Close()
	entries := drain(t, buffer)
	if len(entries) != 150 {
		t.Fatalf("尾部日志数=%d", len(entries))
	}
	for index, entry := range entries {
		if entry.Text != strconv.Itoa(index) {
			t.Fatal("日志重复或顺序改变")
		}
	}
	select {
	case <-unsubscribed:
	default:
		t.Fatal("collector没有unsubscribe")
	}
}
func TestLogsDropOldestWithinLimits(t *testing.T) {
	buffer := &Buffer{}
	for i := 0; i < A.LogEntries+50; i++ {
		buffer.add(ML.Event{LogLevel: ML.INFO, Payload: strings.Repeat("x", 64)})
	}
	next, dropped := buffer.Watermark()
	if len(buffer.entries) != A.LogEntries || dropped != 50 || next != int64(A.LogEntries+50) {
		t.Fatal("队列条数或watermark错误")
	}
	entry, err := buffer.Next(context.Background())
	if err != nil || entry.Seq != 51 {
		t.Fatal("没有整条淘汰最旧日志", err)
	}
}
func TestLogBufferPreservesCredentialLikeText(t *testing.T) {
	texts := []string{"Authorization=Bearer PRIVATE-BEARER", "Authorization: Bearer PRIVATE-BEARER", "authorization: Basic PRIVATE-BASE64", "Proxy-Authorization: Bearer PRIVATE-PROXY", "Cookie: session=PRIVATE-SESSION; refresh=PRIVATE-REFRESH", "Set-Cookie: session=PRIVATE-SESSION; HttpOnly; Secure", `{"password":"PRIVATE-\\slash\"quoted, spaced value","status":200}`, "'password': 'PRIVATE quoted value'", `{"password":"测试非ASCII值"}`, "https://user:PRIVATE-PASSWORD@example.test/path?token=PRIVATE-TOKEN", "password validation failed; status=401"}
	for _, key := range []string{"password", "passwd", "token", "secret", "authorization", "cookie", "private-key"} {
		texts = append(texts, `{"`+key+`" : "PRIVATE value, with punctuation; and spaces"}`)
	}
	buffer := &Buffer{}
	for _, text := range texts {
		buffer.add(ML.Event{LogLevel: ML.INFO, Payload: text})
	}
	for _, text := range texts {
		entry, err := buffer.Next(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := json.Marshal(entry)
		if err != nil {
			t.Fatal(err)
		}
		var actual LogEntry
		if err = json.Unmarshal(encoded, &actual); err != nil || actual.Text != text {
			t.Fatal("传输改变了原始合成日志", err)
		}
	}
	if len(buffer.entries) != 0 || buffer.bytes != 0 {
		t.Fatal("已经传出的日志仍被保留")
	}
}
func TestLogsEnforceTotalByteLimit(t *testing.T) {
	buffer := &Buffer{}
	const count = 200
	text := strings.Repeat("x", 128<<10)
	for i := 0; i < count; i++ {
		buffer.add(ML.Event{LogLevel: ML.INFO, Payload: text})
	}
	next, dropped := buffer.Watermark()
	if buffer.bytes > A.CoreIpcQueueBytes || len(buffer.entries) == 0 || dropped == 0 || next != count {
		t.Fatal("队列超出byte预算或未整条淘汰")
	}
	sum := 0
	for _, entry := range buffer.entries {
		sum += entry.bytes
	}
	if sum != buffer.bytes {
		t.Fatal("byte统计与实际传输帧不符")
	}
	if buffer.bytes+len(text)+5 <= A.CoreIpcQueueBytes {
		t.Fatal("队列提前淘汰日志")
	}
}
func TestLogsSkipOnlyWholeOversizedMessagesAndAdvanceCursor(t *testing.T) {
	for _, unit := range []string{"x", "界", "\x00"} {
		buffer := &Buffer{}
		text := strings.Repeat(unit, (A.CoreIpcRecordBytes-1024)/len(unit))
		buffer.add(ML.Event{LogLevel: ML.INFO, Payload: "first"})
		buffer.add(ML.Event{LogLevel: ML.INFO, Payload: strings.Repeat(unit, A.CoreIpcRecordBytes)})
		buffer.add(ML.Event{LogLevel: ML.INFO, Payload: text})
		buffer.add(ML.Event{LogLevel: ML.INFO, Payload: "last"})
		next, dropped := buffer.Watermark()
		if next != 4 || dropped < 1 {
			t.Fatal("超限日志未推进watermark")
		}
		for len(buffer.entries) > 0 {
			entry, _ := buffer.Next(context.Background())
			if entry.Seq == 2 {
				t.Fatal("超限日志被截断后传出")
			}
			if entry.Seq == 3 && entry.Text != text {
				t.Fatal("合法消息被截断")
			}
		}
	}
}
func TestLogsConsumptionReleasesReferencesWithMonotonicWatermark(t *testing.T) {
	buffer := &Buffer{entries: make([]LogEntry, 0, 4)}
	buffer.add(ML.Event{LogLevel: ML.INFO, Payload: "old"})
	old := buffer.entries[:1]
	entry, err := buffer.Next(context.Background())
	if err != nil || entry.Text != "old" || old[0].Text != "" || buffer.bytes != 0 {
		t.Fatal("消费后仍保留日志引用", err)
	}
	buffer.add(ML.Event{LogLevel: ML.INFO, Payload: "new"})
	next, dropped := buffer.Watermark()
	if next != 2 || dropped != 0 {
		t.Fatal("消费重置了watermark")
	}
	entry, _ = buffer.Next(context.Background())
	if entry.Seq != 2 || entry.Text != "new" {
		t.Fatal("消费后复用旧Seq")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = buffer.Next(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal("空队列不响应取消", err)
	}
}
func TestLogsCloseDuringPublishingAndAllowNewSubscription(t *testing.T) {
	for round := 0; round < 4; round++ {
		buffer := NewBuffer()
		started, published := make(chan struct{}), make(chan struct{})
		go func() {
			close(started)
			for i := 0; i < 200; i++ {
				ML.Infoln("logstream-test-%d-%d", round, i)
			}
			close(published)
		}()
		<-started
		buffer.Close()
		select {
		case <-published:
		case <-time.After(5 * time.Second):
			t.Fatal("Close阻塞publisher")
		}
		_ = drain(t, buffer)
	}
}
