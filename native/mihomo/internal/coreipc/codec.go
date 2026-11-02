package coreipc

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"

	A "clashpseudo/native/internal/appcontract"
)

type Error struct {
	Code     string `json:"code"`
	Message  string `json:"message"`
	Cause    any    `json:"cause,omitempty"`
	causeErr error
}

func (e *Error) Error() string { return e.Message }
func (e *Error) Unwrap() error { return e.causeErr }
func Failure(code string, err error) *Error {
	if err == nil {
		return nil
	}
	if existing, ok := err.(*Error); ok {
		return existing
	}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		children := joined.Unwrap()
		if len(children) == 1 {
			return Failure(code, children[0])
		}
	}
	return &Error{Code: code, Message: err.Error(), Cause: causes(err), causeErr: err}
}
func causes(err error) any {
	if raw, ok := err.(interface{ RawCause() any }); ok {
		return raw.RawCause()
	}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		values := make([]any, 0)
		for _, child := range joined.Unwrap() {
			if child != nil {
				values = append(values, Failure(A.CoreErrorCallFailed, child))
			}
		}
		return values
	}
	if child := errors.Unwrap(err); child != nil {
		return Failure(A.CoreErrorCallFailed, child)
	}
	return nil
}

type Frame struct {
	Kind    byte
	Payload []byte
}

func ReadFrame(r io.Reader) (Frame, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return Frame{}, Failure(A.CoreErrorTransportInterrupted, fmt.Errorf("frame header: %w", err))
	}
	size := binary.BigEndian.Uint32(header[:4])
	if size > A.CoreIpcFrameBytes {
		return Frame{}, Failure(A.CoreErrorInputTooLarge, fmt.Errorf("frame payload %d exceeds %d bytes", size, A.CoreIpcFrameBytes))
	}
	kind := header[4]
	if kind < A.CoreIpcFrameData || kind > A.CoreIpcFrameMetadata {
		return Frame{}, Failure(A.CoreErrorTransportInterrupted, fmt.Errorf("unknown frame kind %d", kind))
	}
	payload := make([]byte, int(size))
	if _, err := io.ReadFull(r, payload); err != nil {
		return Frame{}, Failure(A.CoreErrorTransportInterrupted, fmt.Errorf("frame payload: %w", err))
	}
	return Frame{kind, payload}, nil
}

type Writer struct {
	Output   io.Writer
	Terminal bool
	Count    uint64
}

func (w *Writer) Write(kind byte, payload []byte) error {
	if w.Terminal {
		return Failure(A.CoreErrorTransportInterrupted, errors.New("frame follows terminal"))
	}
	if kind < A.CoreIpcFrameData || kind > A.CoreIpcFrameMetadata {
		return Failure(A.CoreErrorTransportInterrupted, fmt.Errorf("unknown frame kind %d", kind))
	}
	if len(payload) > A.CoreIpcFrameBytes {
		return Failure(A.CoreErrorResultTooLarge, fmt.Errorf("frame payload %d exceeds %d bytes", len(payload), A.CoreIpcFrameBytes))
	}
	var header [5]byte
	binary.BigEndian.PutUint32(header[:4], uint32(len(payload)))
	header[4] = kind
	if err := writeAll(w.Output, header[:]); err != nil {
		return Failure(A.CoreErrorTransportInterrupted, err)
	}
	if err := writeAll(w.Output, payload); err != nil {
		return Failure(A.CoreErrorTransportInterrupted, err)
	}
	if kind == A.CoreIpcFrameTerminal {
		w.Terminal = true
	}
	if kind == A.CoreIpcFrameRecord {
		w.Count++
	}
	return nil
}
func writeAll(w io.Writer, p []byte) error {
	for len(p) != 0 {
		n, err := w.Write(p)
		if err != nil {
			return err
		}
		if n <= 0 || n > len(p) {
			return io.ErrShortWrite
		}
		p = p[n:]
	}
	return nil
}
func (w *Writer) JSON(kind byte, value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if kind == A.CoreIpcFrameData {
		return w.Data(body)
	}
	return w.Write(kind, body)
}
func (w *Writer) Data(body []byte) error {
	for len(body) > A.CoreIpcFrameBytes {
		if err := w.Write(A.CoreIpcFrameData, body[:A.CoreIpcFrameBytes]); err != nil {
			return err
		}
		body = body[A.CoreIpcFrameBytes:]
	}
	return w.Write(A.CoreIpcFrameData, body)
}

var PartLimits = map[string]int{
	A.CorePartRequest:   A.CoreIpcControlBytes,
	A.CorePartConfig:    A.ConfigurationTextBytes,
	A.CorePartOverrides: A.ConfigurationOverrideJsonBytes,
	A.CorePartOptions:   A.ConfigurationPreparationOptionsBytes,
	A.CorePartTrust:     4 << 20,
}

// ReadParts逐段复核实际字节；终态前EOF不算完整输入。
func ReadParts(r io.Reader) (map[string][]byte, error) {
	parts := make(map[string][]byte)
	part := ""
	expected := 0
	completePart := func() error {
		if part != "" && len(parts[part]) != expected {
			return Failure(A.CoreErrorTransportInterrupted, fmt.Errorf("part %q contains %d bytes, expected %d", part, len(parts[part]), expected))
		}
		return nil
	}
	for {
		frame, err := ReadFrame(r)
		if err != nil {
			return nil, err
		}
		switch frame.Kind {
		case A.CoreIpcFrameMetadata:
			if err = completePart(); err != nil {
				return nil, err
			}
			var meta struct {
				Part  string `json:"part"`
				Bytes *int64 `json:"bytes"`
			}
			if !utf8.Valid(frame.Payload) || json.Unmarshal(frame.Payload, &meta) != nil || meta.Bytes == nil || *meta.Bytes < 0 {
				return nil, Failure(A.CoreErrorInvalidEncoding, errors.New("invalid part metadata"))
			}
			limit, ok := PartLimits[meta.Part]
			if !ok {
				return nil, Failure(A.CoreErrorTransportInterrupted, fmt.Errorf("unknown request part %q", meta.Part))
			}
			if _, exists := parts[meta.Part]; exists {
				return nil, Failure(A.CoreErrorTransportInterrupted, fmt.Errorf("duplicate request part %q", meta.Part))
			}
			if *meta.Bytes > int64(limit) {
				return nil, Failure(A.CoreErrorInputTooLarge, fmt.Errorf("part %q exceeds %d bytes", meta.Part, limit))
			}
			part, expected = meta.Part, int(*meta.Bytes)
			parts[part] = make([]byte, 0, expected)
		case A.CoreIpcFrameData:
			if part == "" {
				return nil, Failure(A.CoreErrorTransportInterrupted, errors.New("data precedes part metadata"))
			}
			if len(frame.Payload) > expected-len(parts[part]) {
				return nil, Failure(A.CoreErrorTransportInterrupted, fmt.Errorf("part %q exceeds declared bytes", part))
			}
			parts[part] = append(parts[part], frame.Payload...)
		case A.CoreIpcFrameTerminal:
			if err = completePart(); err != nil {
				return nil, err
			}
			var terminal struct {
				Complete bool `json:"complete"`
			}
			if !utf8.Valid(frame.Payload) || json.Unmarshal(frame.Payload, &terminal) != nil || !terminal.Complete {
				return nil, Failure(A.CoreErrorTransportInterrupted, errors.New("request has no complete terminal"))
			}
			for name, body := range parts {
				if !utf8.Valid(body) {
					return nil, Failure(A.CoreErrorInvalidEncoding, fmt.Errorf("part %q is not UTF-8", name))
				}
			}
			return parts, nil
		default:
			return nil, Failure(A.CoreErrorTransportInterrupted, errors.New("record frame is not a request segment"))
		}
	}
}

type Terminal struct {
	Complete    bool   `json:"complete"`
	RecordCount uint64 `json:"recordCount"`
	Source      string `json:"source,omitempty"`
	Stale       bool   `json:"stale"`
	Error       *Error `json:"error,omitempty"`
	CancelError *Error `json:"cancelError,omitempty"`
	Exited      bool   `json:"exited"`
}
