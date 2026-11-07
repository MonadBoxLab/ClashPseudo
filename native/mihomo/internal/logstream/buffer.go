package logstream

import (
	"context"
	"encoding/json"
	"io"
	"sync"
	"time"

	A "clashpseudo/native/internal/appcontract"
	ML "github.com/metacubex/mihomo/log"
)

type LogEntry struct {
	Seq   int64  `json:"seq"`
	Level string `json:"level"`
	Time  string `json:"time"`
	Text  string `json:"text"`
	bytes int
}

// Buffer is a consumable bounded transport queue; it does not retain log history already delivered to AppRuntime.
type Buffer struct {
	mu            sync.Mutex
	once          sync.Once
	entries       []LogEntry
	bytes         int
	next, dropped int64
	stop, done    chan struct{}
	wake          chan struct{}
}

func NewBuffer() *Buffer {
	b := &Buffer{stop: make(chan struct{}), done: make(chan struct{}), wake: make(chan struct{}, 1)}
	sub := ML.Subscribe()
	go b.collect(sub, func() { ML.UnSubscribe(sub) })
	return b
}
func (b *Buffer) collect(sub <-chan ML.Event, unsubscribe func()) {
	defer close(b.done)
	for {
		select {
		case event, ok := <-sub:
			if !ok {
				return
			}
			b.add(event)
		case <-b.stop:
			drained := make(chan struct{})
			go func() {
				defer close(drained)
				for event := range sub {
					b.add(event)
				}
			}()
			unsubscribe()
			<-drained
			return
		}
	}
}
func (b *Buffer) Close() { b.once.Do(func() { close(b.stop) }); <-b.done }
func (b *Buffer) add(event ML.Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	defer func() {
		select {
		case b.wake <- struct{}{}:
		default:
		}
	}()
	b.next++
	entry := LogEntry{Seq: b.next, Level: event.LogLevel.String(), Time: time.Now().UTC().Format(time.RFC3339Nano), Text: event.Payload}
	encoded, _ := json.Marshal(entry)
	if len(encoded) > A.CoreIpcRecordBytes {
		b.dropped++
		return
	}
	entry.bytes = len(encoded) + 5
	b.entries = append(b.entries, entry)
	b.bytes += entry.bytes
	for b.bytes > A.CoreIpcQueueBytes || len(b.entries) > A.LogEntries {
		b.bytes -= b.entries[0].bytes
		b.entries[0] = LogEntry{}
		b.entries = b.entries[1:]
		b.dropped++
	}
	select {
	case b.wake <- struct{}{}:
	default:
	}
}
func (b *Buffer) Next(ctx context.Context) (LogEntry, error) {
	for {
		b.mu.Lock()
		if len(b.entries) > 0 {
			entry := b.entries[0]
			b.entries[0] = LogEntry{}
			b.entries = b.entries[1:]
			b.bytes -= entry.bytes
			b.mu.Unlock()
			return entry, nil
		}
		b.mu.Unlock()
		select {
		case <-ctx.Done():
			return LogEntry{}, ctx.Err()
		case <-b.done:
			return LogEntry{}, io.EOF
		case <-b.wake:
		}
	}
}
func (b *Buffer) Watermark() (next, dropped int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.next, b.dropped
}
