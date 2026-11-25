package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestToolResponseBlocks(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want []string
	}{
		{"string", `"hello"`, []string{"hello"}},
		{"mcp array", `[{"type":"text","text":"echo: hello probe"}]`, []string{"echo: hello probe"}},
		{"mcp array keeps order and extra keys", `[{"type":"text","text":"a","annotations":{}},{"type":"text","text":"b"}]`, []string{"a", "b"}},
		{"call tool result object", `{"content":[{"type":"text","text":"foo"},{"type":"text","text":"bar"}],"isError":false}`, []string{"foo", "bar"}},
		{"mixed text and image skips image", `[{"type":"text","text":"a"},{"type":"image","data":"AAAA","mimeType":"image/png"},{"type":"text","text":"b"}]`, []string{"a", "b"}},
		{"only images falls back", `[{"type":"image","data":"AAAA"}]`, []string{`[{"type":"image","data":"AAAA"}]`}},
		{"call tool result without text falls back", `{"content":[{"type":"image","data":"AAAA"}]}`, []string{`{"content":[{"type":"image","data":"AAAA"}]}`}},
		{"built-in object falls back compact", "{\n  \"matches\": [\"a\"],\n  \"query\": \"q\"\n}", []string{`{"matches":["a"],"query":"q"}`}},
		{"array without block types falls back", `[1,2]`, []string{`[1,2]`}},
		{"empty array falls back", `[]`, []string{`[]`}},
		{"empty raw", ``, nil},
		{"blank raw", `   `, nil},
		{"invalid JSON kept as is", `{"a":`, []string{`{"a":`}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := toolResponseBlocks(json.RawMessage(tt.raw))
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("toolResponseBlocks(%s) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}

func TestClipIsUTF8Safe(t *testing.T) {
	tests := []struct {
		name string
		in   string
		n    int
		want string
	}{
		{"fits", "abc", 3, "abc"},
		{"ascii cut", "abcdef", 4, "abcd"},
		{"cut inside rune backs off", "aéb", 2, "a"},
		{"cut on rune boundary", "aéb", 3, "aé"},
		{"four byte rune", "😀😀", 5, "😀"},
		{"zero", "abc", 0, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := clip(tt.in, tt.n); got != tt.want {
				t.Fatalf("clip(%q, %d) = %q, want %q", tt.in, tt.n, got, tt.want)
			}
		})
	}
}

func postToolPayloadTexts(t *testing.T, captured map[string]any) []string {
	t.Helper()
	payload := captured["payload"].(map[string]any)
	content := payload["result"].(map[string]any)["content"].([]any)
	texts := make([]string, 0, len(content))
	for _, c := range content {
		block := c.(map[string]any)
		if block["type"] != "text" {
			t.Fatalf("expected text block, got %v", block)
		}
		texts = append(texts, block["text"].(string))
	}
	return texts
}

func TestPostToolUsePayloadBlocks(t *testing.T) {
	tests := []struct {
		name     string
		response any
		maxBytes int
		want     []string
		skipped  bool
	}{
		{"mcp result sent as its blocks", []any{map[string]any{"type": "text", "text": "foo"}}, 0, []string{"foo"}, false},
		{"multi block", []any{map[string]any{"type": "text", "text": "a"}, map[string]any{"type": "text", "text": "b"}}, 0, []string{"a", "b"}, false},
		{"call tool result object", map[string]any{"content": []any{map[string]any{"type": "text", "text": "x"}, map[string]any{"type": "text", "text": "y"}}}, 0, []string{"x", "y"}, false},
		{"budget spans blocks and truncates the last", []any{map[string]any{"type": "text", "text": "aaaa"}, map[string]any{"type": "text", "text": "bbbb"}, map[string]any{"type": "text", "text": "cccc"}}, 6, []string{"aaaa", "bb"}, false},
		{"budget exhausted drops later blocks", []any{map[string]any{"type": "text", "text": "aaaa"}, map[string]any{"type": "text", "text": "bbbb"}}, 4, []string{"aaaa"}, false},
		{"clip does not split a rune", []any{map[string]any{"type": "text", "text": "ééé"}}, 3, []string{"é"}, false},
		{"built-in object is one compact block", map[string]any{"query": "q", "total": 1}, 0, []string{`{"query":"q","total":1}`}, false},
		{"blank blocks skip the evaluate", []any{map[string]any{"type": "text", "text": "  "}, map[string]any{"type": "text", "text": ""}}, 0, nil, true},
		{"empty string skips the evaluate", "", 0, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv, captured := stubGuard(t, EvaluateResponse{Status: "allow"})
			cfg := testConfig(srv.URL)
			if tt.maxBytes > 0 {
				cfg.MaxContentBytes = tt.maxBytes
			}
			_ = invokeHook(t, cfg, map[string]any{
				"hook_event_name": "PostToolUse",
				"tool_name":       "mcp__echo__echo",
				"tool_response":   tt.response,
				"session_id":      "thr_1",
			})
			if tt.skipped {
				if len(*captured) != 0 {
					t.Fatalf("expected no evaluate, got %v", *captured)
				}
				return
			}
			if (*captured)["direction"] != "output" || (*captured)["protocol"] != "mcp" {
				t.Fatalf("unexpected envelope: %v", *captured)
			}
			got := postToolPayloadTexts(t, *captured)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("blocks = %q, want %q", got, tt.want)
			}
			if total := len(strings.Join(got, "")); tt.maxBytes > 0 && total > tt.maxBytes {
				t.Fatalf("sent %d bytes, budget %d", total, tt.maxBytes)
			}
		})
	}
}
