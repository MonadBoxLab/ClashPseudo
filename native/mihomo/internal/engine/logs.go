package engine

import (
	"encoding/json"
	"regexp"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	ML "github.com/metacubex/mihomo/log"
)

const (
	maxLogEntries = 1000
	maxLogBytes   = 1 << 20
	maxLogLine    = 8 << 10
)

// The subscription channel is buffered (200) and upstream logging blocks when
// it fills, so the reader must always drain and bound its own copy instead.
type LogEntry struct {
	Seq       int64  `json:"seq"`
	Level     string `json:"level"`
	Time      string `json:"time"`
	Text      string `json:"text"`
	Truncated bool   `json:"truncated,omitempty"`
}

type LogQuery struct {
	After  int64  `json:"after"`
	Limit  int    `json:"limit"`
	Window string `json:"window,omitempty"`
}

type LogPage struct {
	Window  string     `json:"window"`
	Entries []LogEntry `json:"entries"`
	Next    int64      `json:"next"`
	Dropped int64      `json:"dropped"`
	Total   int        `json:"total"`
}

var logWindowSequence atomic.Uint64

type logBuffer struct {
	mu      sync.Mutex
	window  string
	once    sync.Once
	entries []LogEntry
	bytes   int
	next    int64
	dropped int64
	stop    chan struct{}
	done    chan struct{}
}

func newLogBuffer() *logBuffer {
	buffer := &logBuffer{window: strconv.FormatUint(logWindowSequence.Add(1), 10),
		stop: make(chan struct{}), done: make(chan struct{})}
	subscription := ML.Subscribe()
	go buffer.collect(subscription, func() { ML.UnSubscribe(subscription) })
	return buffer
}

func (b *logBuffer) collect(subscription <-chan ML.Event, unsubscribe func()) {
	defer close(b.done)
	for {
		select {
		case <-b.stop:
			// Drain accepted events concurrently while UnSubscribe acquires the observable lock
			// shared with Emit's 200-slot channel send.
			drained := make(chan struct{})
			go func() {
				defer close(drained)
				for event := range subscription {
					b.add(event)
				}
			}()
			unsubscribe()
			<-drained
			return
		case event, ok := <-subscription:
			if !ok {
				return
			}
			b.add(event)
		}
	}
}

// Request unsubscribe and await reader completion through the bounded close path.
func (b *logBuffer) close() {
	b.once.Do(func() { close(b.stop) })
	select {
	case <-b.done:
	case <-time.After(2 * time.Second):
	}
}

func (b *logBuffer) add(event ML.Event) {
	level := event.LogLevel.String()
	text, truncated := truncateLog(sanitizeLog(event.Payload))
	b.mu.Lock()
	defer b.mu.Unlock()
	b.next++
	entry := LogEntry{Seq: b.next, Level: level, Time: time.Now().UTC().Format(time.RFC3339Nano),
		Text: text, Truncated: truncated}
	b.entries = append(b.entries, entry)
	b.bytes += len(text)
	for len(b.entries) > maxLogEntries || b.bytes > maxLogBytes {
		b.bytes -= len(b.entries[0].Text)
		b.entries = b.entries[1:]
		b.dropped++
	}
}

func (b *logBuffer) page(query LogQuery) LogPage {
	if query.Limit <= 0 {
		query.Limit = 200
	}
	if query.Limit > 500 {
		query.Limit = 500
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	page := LogPage{Window: b.window, Entries: make([]LogEntry, 0, query.Limit), Dropped: b.dropped,
		Total: len(b.entries), Next: query.After}
	for _, entry := range b.entries {
		if entry.Seq <= query.After {
			continue
		}
		if len(page.Entries) == query.Limit {
			break
		}
		page.Entries = append(page.Entries, entry)
		page.Next = entry.Seq
	}
	return page
}

// Redact recognized credential and URL patterns in free-form messages.
var (
	logUserInfo = regexp.MustCompile(`(://)[^/@\s]+@`)
	// Bare credential headers own the rest of their line, including an auth
	// scheme or additional cookies. Quoted JSON keys use logSecret instead.
	logCredentialHeader = regexp.MustCompile(`(?i)(\b(?:authorization|proxy-authorization|cookie|set-cookie)[ \t]*[=:][ \t]*)[^\r\n]+`)
	// Preserve quoted field/value delimiters while consuming escaped quotes and
	// spaces inside the value, rather than leaving the credential behind.
	logSecret = regexp.MustCompile(`(?i)(\b(?:password|passwd|token|secret|authorization|cookie|private-key)["']?\s*[=:]\s*)(?:(")(?:\\.|[^"\\])*"|(')(?:\\.|[^'\\])*'|(?:Bearer|Basic)\s+[^\s,;"']+|[^\s,;"']+)`)
)

func sanitizeLog(text string) string {
	text = logUserInfo.ReplaceAllString(text, "$1[redacted]@")
	text = logCredentialHeader.ReplaceAllString(text, "$1[redacted]")
	return logSecret.ReplaceAllString(text, "${1}${2}${3}[redacted]${2}${3}")
}

func truncateLog(text string) (string, bool) {
	if len(text) <= maxLogLine {
		return text, false
	}
	cut := maxLogLine
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return text[:cut], true
}

func (e *Engine) Logs(query LogQuery) (string, error) {
	e.mu.Lock()
	buffer := e.logs
	e.mu.Unlock()
	if buffer == nil || (query.Window != "" && query.Window != buffer.window) {
		return "", ErrStopped
	}
	data, err := json.Marshal(buffer.page(query))
	if err != nil {
		return "", err
	}
	return string(data), nil
}
