package engine

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	ML "github.com/metacubex/mihomo/log"
)

func TestLogsBoundRedactAndPaginate(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("rules:\n - MATCH,DIRECT\n"), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	ML.Infoln("connect https://user:pass@example.test/path?token=abc")
	ML.Warnln("password=hunter2 retrying")
	long := strings.Repeat("日", maxLogLine)
	ML.Errorln("%s", long)

	// The subscription reader is asynchronous; wait for the sentinels.
	var value string
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		var err error
		value, err = e.Logs(LogQuery{})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(value, "password=[redacted]") && strings.Contains(value, `"truncated":true`) {
			break
		}
	}
	if strings.Contains(value, "user:pass") || strings.Contains(value, "hunter2") {
		t.Fatalf("log buffer kept credentials: %s", value)
	}
	var page LogPage
	if err := json.Unmarshal([]byte(value), &page); err != nil {
		t.Fatal(err)
	}
	// Preparation itself emits core events, so locate the sentinel lines.
	var redacted, secret, truncated *LogEntry
	for i := range page.Entries {
		entry := &page.Entries[i]
		switch {
		case strings.Contains(entry.Text, "[redacted]@example.test"):
			redacted = entry
			if entry.Level != "info" {
				t.Fatalf("level: %+v", entry)
			}
		case strings.Contains(entry.Text, "password=[redacted]"):
			secret = entry
			if entry.Level != "warning" {
				t.Fatalf("level: %+v", entry)
			}
		case entry.Truncated:
			truncated = entry
		}
	}
	if redacted == nil || secret == nil || truncated == nil {
		t.Fatalf("missing sentinels: %+v", page.Entries)
	}
	if len(truncated.Text) > maxLogLine || !utf8.ValidString(truncated.Text) ||
		truncated.Level != "error" {
		t.Fatalf("truncation: %+v", truncated)
	}
	if page.Next != page.Entries[len(page.Entries)-1].Seq {
		t.Fatal(page.Next)
	}

	next, err := e.Logs(LogQuery{After: redacted.Seq, Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	var second LogPage
	if json.Unmarshal([]byte(next), &second) != nil {
		t.Fatal()
	}
	// The sentinel lines may be adjacent to core events; paging must return the
	// immediate successor sequence, whichever event that is.
	if len(second.Entries) != 1 || second.Entries[0].Seq != redacted.Seq+1 {
		t.Fatalf("paging: %+v", second)
	}

	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	retained, err := e.Logs(LogQuery{Limit: 500})
	if err != nil || !strings.Contains(retained, "password=[redacted]") {
		t.Fatalf("stopped session lost its recent window: %s %v", retained, err)
	}
	ML.Infoln("unrelated event after stop")
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	again, err := e.Logs(LogQuery{Limit: 500})
	if err != nil || again != retained {
		t.Fatalf("closed window changed or repeated stop failed: %v", err)
	}
}

func TestFailedPreparationKeepsOnlyItsOwnClosedLogWindow(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("rules:\n - MATCH,DIRECT\n"), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	e.logs.add(ML.Event{LogLevel: ML.INFO, Payload: "previous session sentinel"})
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	previous := e.logs
	previousWindow := previous.window
	if previousWindow == "" {
		t.Fatal("native window has no identity")
	}
	if err := e.Prepare(t.TempDir(), []byte("rules: [invalid"), "rule", nil, func(int) bool { return true }); err == nil {
		t.Fatal("invalid configuration prepared")
	}
	if e.logs == nil || e.logs == previous || e.logs.window == previousWindow {
		t.Fatal("failed prepare discarded the new window or reused the previous session")
	}
	if _, err := e.Logs(LogQuery{Window: previousWindow}); err == nil {
		t.Fatal("old source read a replacement window")
	}
	select {
	case <-e.logs.done:
	default:
		t.Fatal("failed prepare left the subscription running")
	}
	before, err := e.Logs(LogQuery{})
	if err != nil || strings.Contains(before, "previous session sentinel") {
		t.Fatalf("failed session has no independent window: %s %v", before, err)
	}
	ML.Infoln("unrelated event after failure")
	after, err := e.Logs(LogQuery{})
	if err != nil || after != before {
		t.Fatal("failed window still subscribed")
	}
}

func TestClosingLogsPreservesQueuedTailAndIsIdempotent(t *testing.T) {
	buffer := &logBuffer{stop: make(chan struct{}), done: make(chan struct{})}
	defer buffer.close()
	sentinel := t.Name() + " queued tail "
	// These events have entered the subscription channel.
	subscription := make(chan ML.Event, 200)
	for index := 0; index < 150; index++ {
		subscription <- ML.Event{LogLevel: ML.INFO, Payload: sentinel + strconv.Itoa(index)}
	}
	unsubscribed := make(chan struct{})
	go buffer.collect(subscription, func() {
		close(subscription)
		close(unsubscribed)
	})
	buffer.close()
	buffer.close()
	page := buffer.page(LogQuery{Limit: 500})
	seen := make(map[string]bool)
	for _, entry := range page.Entries {
		if strings.HasPrefix(entry.Text, sentinel) {
			if seen[entry.Text] {
				t.Fatalf("duplicate accepted event: %s", entry.Text)
			}
			seen[entry.Text] = true
		}
	}
	for index := 0; index < 150; index++ {
		if !seen[sentinel+strconv.Itoa(index)] {
			t.Fatalf("unsubscribe discarded accepted event %d (%d sentinels retained)", index, len(seen))
		}
	}
	select {
	case <-unsubscribed:
	default:
		t.Fatal("collector did not unsubscribe")
	}
	select {
	case <-buffer.done:
	default:
		t.Fatal("collector still accepts events after close")
	}
}

func TestLogsDropOldestWithinLimits(t *testing.T) {
	buffer := newLogBuffer()
	defer buffer.close()
	for i := 0; i < maxLogEntries+50; i++ {
		ML.Infoln("%s", strings.Repeat("x", 64))
	}
	var page LogPage
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		page = buffer.page(LogQuery{Limit: 500})
		if page.Total == maxLogEntries {
			break
		}
	}
	if page.Total != maxLogEntries {
		t.Fatal(page.Total)
	}
	if page.Dropped == 0 {
		t.Fatal("dropped counter did not move")
	}
	if page.Next != page.Entries[len(page.Entries)-1].Seq {
		t.Fatal(page.Next)
	}
}

func TestSanitizeLogRecognizedCredentials(t *testing.T) {
	for _, test := range []struct {
		name, text, want string
	}{
		{"bearer assignment", "Authorization=Bearer PRIVATE-BEARER", "Authorization=[redacted]"},
		{"bearer header", "Authorization: Bearer PRIVATE-BEARER", "Authorization: [redacted]"},
		{"basic header", "authorization: Basic PRIVATE-BASE64", "authorization: [redacted]"},
		{"proxy header", "Proxy-Authorization: Bearer PRIVATE-PROXY", "Proxy-Authorization: [redacted]"},
		{"cookie header", "Cookie: session=PRIVATE-SESSION; refresh=PRIVATE-REFRESH", "Cookie: [redacted]"},
		{"set cookie header", "Set-Cookie: session=PRIVATE-SESSION; HttpOnly; Secure", "Set-Cookie: [redacted]"},
		{"json password", `{"password":"PRIVATE-PASSWORD","status":"public"}`, `{"password":"[redacted]","status":"public"}`},
		{"json escaped password", `{"password":"PRIVATE-\\slash\"quoted, spaced value","status":200}`, `{"password":"[redacted]","status":200}`},
		{"single quoted password", "'password': 'PRIVATE quoted value'", "'password': '[redacted]'"},
		{"unicode password", `{"password":"秘密🔐值"}`, `{"password":"[redacted]"}`},
		{"json authorization", `{"Authorization":"Bearer PRIVATE-BEARER","status":200}`, `{"Authorization":"[redacted]","status":200}`},
		{"json cookie", `{"cookie":"session=PRIVATE-SESSION; refresh=PRIVATE-REFRESH"}`, `{"cookie":"[redacted]"}`},
		{"url user info and token", "https://user:PRIVATE-PASSWORD@example.test/path?token=PRIVATE-TOKEN", "https://[redacted]@example.test/path?token=[redacted]"},
		{"plain event", "password validation failed; status=401", "password validation failed; status=401"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := sanitizeLog(test.text); got != test.want {
				t.Fatalf("sanitizeLog() = %q, want %q", got, test.want)
			}
		})
	}
	for _, key := range []string{"password", "passwd", "token", "secret", "authorization", "cookie", "private-key"} {
		t.Run("quoted field "+key, func(t *testing.T) {
			text := `{"` + key + `" : "PRIVATE value, with punctuation; and spaces"}`
			want := `{"` + key + `" : "[redacted]"}`
			if got := sanitizeLog(text); got != want {
				t.Fatalf("sanitizeLog() = %q, want %q", got, want)
			}
		})
	}
}

func TestLogsEnforceTotalByteLimit(t *testing.T) {
	buffer := &logBuffer{}
	const count = 200
	for i := 0; i < count; i++ {
		buffer.add(ML.Event{LogLevel: ML.INFO, Payload: strings.Repeat("x", maxLogLine)})
	}
	page := buffer.page(LogQuery{Limit: 500})
	retained := maxLogBytes / maxLogLine
	if buffer.bytes != maxLogBytes || page.Total != retained || len(page.Entries) != retained || page.Dropped != int64(count-retained) {
		t.Fatalf("byte bound: bytes=%d total=%d entries=%d dropped=%d", buffer.bytes, page.Total, len(page.Entries), page.Dropped)
	}
	if page.Entries[0].Seq != int64(count-retained+1) || page.Next != count {
		t.Fatalf("oldest entries were not evicted: first=%d next=%d", page.Entries[0].Seq, page.Next)
	}
	buffer.add(ML.Event{LogLevel: ML.INFO, Payload: "small"})
	if buffer.bytes > maxLogBytes || buffer.bytes != maxLogBytes-maxLogLine+len("small") {
		t.Fatalf("mixed-size byte bound: %d", buffer.bytes)
	}
}

func TestLogsCloseDuringPublishingAndAllowNewSubscription(t *testing.T) {
	for round := 0; round < 4; round++ {
		buffer := newLogBuffer()
		closed := false
		defer func() {
			if !closed {
				buffer.close()
			}
		}()
		started, published := make(chan struct{}), make(chan struct{})
		go func() {
			defer close(published)
			for i := 0; i < 1000; i++ {
				ML.Debugln("log cancellation fixture")
				if i == 31 {
					close(started)
				}
			}
		}()
		select {
		case <-started:
		case <-time.After(3 * time.Second):
			t.Fatal("publisher did not start")
		}
		buffer.close()
		closed = true
		select {
		case <-buffer.done:
		default:
			t.Fatal("close returned before its subscription stopped")
		}
		select {
		case <-published:
		case <-time.After(3 * time.Second):
			t.Fatal("closing the log subscription blocked upstream publishing")
		}
	}
	fresh := newLogBuffer()
	defer fresh.close()
	const sentinel = "fresh log subscription sentinel"
	ML.Debugln(sentinel)
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(time.Millisecond) {
		for _, entry := range fresh.page(LogQuery{}).Entries {
			if entry.Text == sentinel {
				return
			}
		}
	}
	t.Fatal("a fresh subscription did not receive events after cancellation")
}

func TestTruncateLogExactUTF8Boundaries(t *testing.T) {
	for _, test := range []struct {
		name, text string
		length     int
		truncated  bool
	}{
		{"exact ascii", strings.Repeat("x", maxLogLine), maxLogLine, false},
		{"over ascii", strings.Repeat("x", maxLogLine+1), maxLogLine, true},
		{"exact utf8", strings.Repeat("界", maxLogLine/3) + strings.Repeat("x", maxLogLine%3), maxLogLine, false},
		{"split three bytes", strings.Repeat("x", maxLogLine-2) + "界", maxLogLine - 2, true},
		{"split four bytes", strings.Repeat("x", maxLogLine-3) + "🔐", maxLogLine - 3, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, truncated := truncateLog(test.text)
			if len(got) != test.length || truncated != test.truncated || !utf8.ValidString(got) {
				t.Fatalf("truncateLog(): bytes=%d truncated=%v valid=%v", len(got), truncated, utf8.ValidString(got))
			}
		})
	}
	buffer := &logBuffer{}
	buffer.add(ML.Event{LogLevel: ML.INFO, Payload: strings.Repeat("界", maxLogLine/3-20) + ` password="` + strings.Repeat("PRIVATE", maxLogLine) + `"`})
	page := buffer.page(LogQuery{})
	if len(page.Entries) != 1 || len(page.Entries[0].Text) > maxLogLine || !utf8.ValidString(page.Entries[0].Text) || strings.Contains(page.Entries[0].Text, "PRIVATE") {
		t.Fatal("redaction/truncation retained a credential or exceeded the UTF-8 byte bound")
	}
}

func TestSanitizeAndTruncateStayUTF8Safe(t *testing.T) {
	if got := sanitizeLog("token=abc Authorization: Bearer x"); strings.Contains(got, "abc") || strings.Contains(got, "Bearer") {
		t.Fatal(got)
	}
	text := strings.Repeat("界", maxLogLine)
	cut, truncated := truncateLog(text)
	if !truncated || !utf8.ValidString(cut) || len(cut) > maxLogLine {
		t.Fatal(len(cut), truncated)
	}
}
