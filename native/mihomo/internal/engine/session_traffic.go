package engine

// Capture the process-wide tracker baseline for the accepted VPN lease before executor
// and ingress activation.
type trafficBaseline struct{ upload, download int64 }

func (b *trafficBaseline) totals(up, down int64) (*int64, *int64) {
	if b == nil || b.upload < 0 || b.download < 0 || up < b.upload || down < b.download {
		return nil, nil
	}
	u, d := up-b.upload, down-b.download
	return &u, &d
}
