package engine

import (
	"clashpseudo/native/internal/logstream"
	"context"
)

func (e *Engine) LogQueue() *logstream.Buffer {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.logs == nil {
		e.logs = logstream.NewBuffer()
	}
	return e.logs
}
func (e *Engine) StreamLogs(ctx context.Context, emit func(logstream.LogEntry) error) error {
	queue := e.LogQueue()
	for {
		entry, err := queue.Next(ctx)
		if err != nil {
			return err
		}
		if err = emit(entry); err != nil {
			return err
		}
	}
}
