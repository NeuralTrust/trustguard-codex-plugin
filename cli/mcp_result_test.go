package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// TrustGate sends the whole CallToolResult as decoded, plus one text block listing
// structuredContent. These literals are what its builder produces for the same bodies.
func TestMCPResultIsSentWholeWithTheStructuredBlock(t *testing.T) {
	tests := []struct {
		name string
		resp string
		want string
	}{
		{
			"codex shaped result",
			`{"content":[{"type":"text","text":"notes"}],"structuredContent":{"bytes":5}}`,
			`{"content":[{"type":"text","text":"notes"},{"type":"text","text":"bytes\n5"}],"structuredContent":{"bytes":5}}`,
		},
		{
			"isError true",
			`{"content":[{"type":"text","text":"notes"}],"structuredContent":{"bytes":5},"isError":true}`,
			`{"content":[{"type":"text","text":"notes"},{"type":"text","text":"bytes\n5"}],"structuredContent":{"bytes":5},"isError":true}`,
		},
		{
			"nested structuredContent: sorted keys, arrays, null, bool, numbers",
			`{"content":[{"type":"text","text":"\"a\" \"b\" \"c\" \"d\" \"e\" \"f\" \"g\" \"h\""}],"structuredContent":{"b":[1.50,null,true,"s"],"a":{"z":"w","y":false}}}`,
			`{"content":[{"type":"text","text":"\"a\" \"b\" \"c\" \"d\" \"e\" \"f\" \"g\" \"h\""},{"type":"text","text":"a\ny\nfalse\nz\nw\nb\n1.50\nnull\ntrue\ns"}],"structuredContent":{"b":[1.50,null,true,"s"],"a":{"z":"w","y":false}}}`,
		},
		{
			"blank strings and blank keys are skipped",
			`{"content":[{"type":"text","text":"x"}],"structuredContent":{" ":"  ","k":" ","m":"v"}}`,
			`{"content":[{"type":"text","text":"x"},{"type":"text","text":"k\nm\nv"}],"structuredContent":{" ":"  ","k":" ","m":"v"}}`,
		},
		{
			"empty structuredContent adds no block",
			`{"content":[{"type":"text","text":"notes"}],"structuredContent":{}}`,
			`{"content":[{"type":"text","text":"notes"}],"structuredContent":{}}`,
		},
		{
			"null structuredContent adds no block",
			`{"content":[{"type":"text","text":"notes"}],"structuredContent":null}`,
			`{"content":[{"type":"text","text":"notes"}],"structuredContent":null}`,
		},
		{
			"empty content with structuredContent",
			`{"content":[],"structuredContent":{"bytes":5}}`,
			`{"content":[{"type":"text","text":"bytes\n5"}],"structuredContent":{"bytes":5}}`,
		},
		{
			"no structuredContent keeps isError",
			`{"content":[{"type":"text","text":"a"}],"isError":false}`,
			`{"content":[{"type":"text","text":"a"}],"isError":false}`,
		},
	}
	senders := []func(*testing.T, int, string, string) (map[string]any, bool){sendToolResult}
	for _, send := range senders {
		for _, tt := range tests {
			t.Run(tt.name, func(t *testing.T) {
				got, sent := send(t, 0, "mcp__echo__echo", tt.resp)
				if !sent {
					t.Fatalf("no evaluate sent for %s", tt.resp)
				}
				var want any
				if err := json.Unmarshal([]byte(tt.want), &want); err != nil {
					t.Fatal(err)
				}
				result := got["payload"].(map[string]any)["result"]
				if !reflect.DeepEqual(result, want) {
					t.Fatalf("result = %v, want %v", result, want)
				}
			})
		}
	}
}

// Numbers reach TrustGuard as written, not re-encoded.
func TestMCPResultKeepsNumbersAsWritten(t *testing.T) {
	raw := json.RawMessage(`{"content":[{"type":"text","text":"x"}],"structuredContent":{"n":1.50,"big":12345678901234567890}}`)
	main := []any{map[string]any{"type": "text", "text": strings.Repeat("x", 500)}}
	budget := 1000
	result, ok := mcpResult("mcp__echo__echo", raw, budget, main)
	if !ok {
		t.Fatal("expected the whole result")
	}
	enc, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"n":1.50`, `"big":12345678901234567890`, `"text":"big\n12345678901234567890\nn\n1.50"`} {
		if !strings.Contains(string(enc), want) {
			t.Fatalf("%s does not contain %s", enc, want)
		}
	}
}

// A result whose structuredContent repeats the content text is larger than the single
// clipped block, and is still sent whole while it fits the budget.
func TestMCPResultDuplicatedStructuredContentIsSentWhole(t *testing.T) {
	text := strings.Repeat("line of \"quoted\" text\n", 45)
	body, _ := json.Marshal(map[string]any{
		"content":           []any{map[string]any{"type": "text", "text": text}},
		"structuredContent": map[string]any{"result": text},
	})
	senders := []func(*testing.T, int, string, string) (map[string]any, bool){sendToolResult}
	for _, send := range senders {
		got, sent := send(t, 0, "mcp__echo__echo", string(body))
		if !sent {
			t.Fatal("no evaluate sent")
		}
		result := got["payload"].(map[string]any)["result"].(map[string]any)
		if _, ok := result["structuredContent"]; !ok {
			t.Fatalf("expected the whole result, got %v", result)
		}
		blocks := result["content"].([]any)
		if len(blocks) != 2 || blocks[1].(map[string]any)["text"] != "result\n"+text {
			t.Fatalf("unexpected blocks: %v", blocks)
		}
		if len(body) < 1800 || len(body) > 2600 {
			t.Fatalf("body is %d bytes, want about 2 KB", len(body))
		}
	}
}

// The budget applies to the result as it is sent: HTML characters are escaped to six bytes.
func TestMCPResultBudgetCountsTheEscapedEncoding(t *testing.T) {
	raw := json.RawMessage(`{"content":[{"type":"text","text":"a"}],"structuredContent":{"k":"` + strings.Repeat("<", 60) + `"}}`)
	main := []any{map[string]any{"type": "text", "text": "x"}}
	for _, tt := range []struct {
		budget int
		ok     bool
	}{{1000, true}, {300, false}} {
		result, ok := mcpResult("mcp__echo__echo", raw, tt.budget, main)
		if ok != tt.ok {
			t.Fatalf("budget %d: ok = %v, want %v", tt.budget, ok, tt.ok)
		}
		if ok {
			if enc, _ := json.Marshal(result); len(enc) > tt.budget {
				t.Fatalf("sent %d bytes over a budget of %d", len(enc), tt.budget)
			}
		}
	}
}
