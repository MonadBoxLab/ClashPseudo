package engine

import (
	"errors"

	"clashpseudo/native/internal/coreview"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func (e *Engine) Connections(q coreview.ConnectionQuery) (string, error) {
	if err := q.Validate(); err != nil {
		return "", err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() || e.options.Purpose != "RUNNING" {
		return "", ErrStopped
	}
	upload, download := statistic.DefaultManager.Total()
	sessionUpload, sessionDownload := e.traffic.totals(upload, download)
	totals := coreview.ConnectionTotals{
		Upload: upload, Download: download,
		SessionUpload: sessionUpload, SessionDownload: sessionDownload,
	}
	return coreview.Connections(statistic.DefaultManager, e.cfg.Proxies, q, totals)
}

func (e *Engine) CloseConnection(id string) (string, error) {
	if !coreview.ValidConnectionID(id) {
		return "", errors.New("invalid connection ID")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() || e.options.Purpose != "RUNNING" {
		return "", ErrStopped
	}
	return closeConnection(statistic.DefaultManager, id)
}

func closeConnection(source interface {
	Get(string) statistic.Tracker
}, id string) (string, error) {
	tracker := source.Get(id)
	if tracker == nil {
		return "absent", nil
	}
	if err := tracker.Close(); err != nil {
		// Tracker.Close may remove the record before the underlying Close fails.
		return "", err
	}
	return "closed", nil
}
