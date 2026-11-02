package main

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
)

// callbackFailure保留平台返回的原始error对象及cause和suppressed。
type callbackFailure struct{ raw json.RawMessage }

func (e *callbackFailure) Error() string { return string(e.raw) }
func (e *callbackFailure) RawCause() any { return e.raw }
func decodeCallback(body []byte, target any) error {
	if len(body) == 0 {
		return errors.New("Android callback returned no result")
	}
	if err := json.Unmarshal(body, target); err != nil {
		return err
	}
	var envelope struct {
		Error json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return err
	}
	if len(envelope.Error) != 0 && string(envelope.Error) != "null" && string(envelope.Error) != `""` {
		return &callbackFailure{raw: append(json.RawMessage(nil), envelope.Error...)}
	}
	return nil
}

type platformCancellationError struct{ err error }

func (e *platformCancellationError) Error() string            { return e.err.Error() }
func (e *platformCancellationError) Unwrap() error            { return e.err }
func (e *platformCancellationError) CancellationCause() error { return e.err }

// invokePlatformQuery只在原同步callback仍等待时发送取消，完成后不补发取消。
func invokePlatformQuery(ctx context.Context, run func() []byte, cancel func() error) ([]byte, error) {
	var mu sync.Mutex
	waiting := true
	var cancelErr error
	cancelDone := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		defer close(cancelDone)
		mu.Lock()
		defer mu.Unlock()
		if waiting {
			cancelErr = cancel()
		}
	})
	body := run()
	mu.Lock()
	waiting = false
	mu.Unlock()
	if !stop() {
		<-cancelDone
	}
	if cancelErr != nil {
		return body, &platformCancellationError{err: cancelErr}
	}
	return body, nil
}
func callbackCancellation(err error) error {
	var value interface{ CancellationCause() error }
	if errors.As(err, &value) {
		return value.CancellationCause()
	}
	return nil
}
