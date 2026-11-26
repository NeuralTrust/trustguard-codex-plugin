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
			"_meta is kept",
			`{"content":[{"type":"text","text":"notes"}],"structuredContent":{"bytes":5},"_meta":{"k":"v","n":[1,2]}}`,
			`{"content":[{"type":"text","text":"notes"},{"type":"text","text":"bytes\n5"}],"structuredContent":{"bytes":5},"_meta":{"k":"v","n":[1,2]}}`,
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
			"no structuredContent keeps isError and _meta",
			`{"content":[{"type":"text","text":"a"}],"isError":false,"_meta":{"k":"v"}}`,
			`{"content":[{"type":"text","text":"a"}],"isError":false,"_meta":{"k":"v"}}`,
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
