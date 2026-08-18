package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

const maxResponseBytes = 1 << 20

// EvaluateRequest is the wire body for POST /v1/evaluate. A collector API key
// binds the collector server-side, so no gateway_id/collector_key is sent.
type EvaluateRequest struct {
	Payload    map[string]any `json:"payload"`
	Direction  string         `json:"direction"`
	Protocol   string         `json:"protocol"`
	SessionID  string         `json:"session_id,omitempty"`
	ConsumerID string         `json:"consumer_id,omitempty"`
	Attributes map[string]any `json:"attributes,omitempty"`
}

// EvaluateResponse mirrors TrustGuard's findings envelope (docs/api/findings.md).
type EvaluateResponse struct {
	Status             string         `json:"status"`
	Findings           []Finding      `json:"findings"`
	TraceID            string         `json:"trace_id"`
	RequestID          string         `json:"request_id"`
	TransformedPayload map[string]any `json:"transformed_payload"`
}

type Finding struct {
	Source   FindingSource   `json:"source"`
	Signal   *FindingSignal  `json:"signal,omitempty"`
	Outcome  *FindingOutcome `json:"outcome,omitempty"`
	Evidence map[string]any  `json:"evidence,omitempty"`
}

type FindingSource struct {
	Kind         string `json:"kind"`
	Plugin       string `json:"plugin,omitempty"`
	DetectorName string `json:"detector_name,omitempty"`
	GateName     string `json:"gate_name,omitempty"`
	PolicyID     string `json:"policy_id,omitempty"`
}

type FindingSignal struct {
	Type       string  `json:"type"`
	Confidence float64 `json:"confidence,omitempty"`
}

type FindingOutcome struct {
	Action string `json:"action"`
}

type guardClient struct {
	baseURL string
	apiKey  string
	http    *http.Client
}

func newGuardClient(cfg Config) *guardClient {
	return &guardClient{
		baseURL: strings.TrimRight(cfg.DataURL, "/"),
		apiKey:  cfg.APIKey,
		http:    &http.Client{Timeout: cfg.timeout()},
	}
}

// Evaluate posts one payload to /v1/evaluate. Detections come back as HTTP 200;
// any non-200 (auth, validation, rate limit, outage) is returned as an error so
// the caller applies the configured fail mode.
func (c *guardClient) Evaluate(ctx context.Context, req EvaluateRequest) (*EvaluateResponse, error) {
	raw, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("encode evaluate request: %w", err)
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/evaluate", bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("build evaluate request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)

	res, err := c.http.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("call trustguard: %w", err)
	}
	defer res.Body.Close()

	body, err := io.ReadAll(io.LimitReader(res.Body, maxResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("read evaluate response: %w", err)
	}
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("trustguard HTTP %d: %s", res.StatusCode, truncate(string(body), 200))
	}
	var parsed EvaluateResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("decode evaluate response: %w", err)
	}
	return &parsed, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
