package main

import (
	"bytes"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
)

// mcpResult returns an MCP tool result in the shape TrustGate sends it, so TrustGuard
// scores the same text. A CallToolResult object is sent with every field unchanged,
// plus one extra text block listing the keys and values of structuredContent. ok is
// false unless every content block is plain text, the object has no fields beyond
// content, structuredContent, isError and _meta, and the result fits the budget and is
// no larger than main.
func mcpResult(toolName string, raw json.RawMessage, budget int, main []any) (result map[string]any, ok bool) {
	if !strings.HasPrefix(toolName, "mcp__") {
		return nil, false
	}
	raw = json.RawMessage(bytes.TrimSpace(raw))
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) == nil {
		return mcpResultObject(raw, fields, budget, main)
	}
	return mcpContentList(raw, budget, main)
}

// mcpContentList handles a bare content array: the blocks, wrapped as {"content": blocks}.
func mcpContentList(raw json.RawMessage, budget int, main []any) (map[string]any, bool) {
	content, ok := textBlocks(raw, budget)
	if !ok {
		return nil, false
	}
	result := map[string]any{"content": content}
	if !inspectable(result) {
		return nil, false
	}
	// The blocks are used only when they are no larger on the wire than the single block.
	blocksJSON, _ := json.Marshal(content)
	mainJSON, _ := json.Marshal(main)
	if len(blocksJSON) > len(mainJSON) {
		return nil, false
	}
	return result, true
}

// mcpResultObject handles a CallToolResult object.
func mcpResultObject(raw json.RawMessage, fields map[string]json.RawMessage, budget int, main []any) (map[string]any, bool) {
	for k, v := range fields {
		switch k {
		case "content", "structuredContent", "_meta":
		case "isError":
			if s := string(bytes.TrimSpace(v)); s != "true" && s != "false" {
				return nil, false
			}
		default:
			return nil, false
		}
	}
	list, has := fields["content"]
	if !has {
		return nil, false
	}
	content, ok := textBlocks(list, budget)
	if !ok {
		return nil, false
	}
	var result map[string]any
	if decodeNumbers(raw, &result) != nil {
		return nil, false
	}
	result["content"] = content
	if probe, ok := structuredProbe(result); ok {
		result["content"] = append(content, map[string]any{"type": "text", "text": probe})
	}
	if !inspectable(result) {
		return nil, false
	}
	resultJSON, _ := json.Marshal(result)
	mainJSON, _ := json.Marshal(map[string]any{"content": main})
	if len(resultJSON) > budget || len(resultJSON) > len(mainJSON) {
		return nil, false
	}
	return result, true
}

// textBlocks returns the blocks of a content array when every block is plain text and
// the blocks fit the budget. The blocks are returned in canonical form.
func textBlocks(list json.RawMessage, budget int) ([]any, bool) {
	list = bytes.TrimSpace(list)
	var blocks []json.RawMessage
	if len(list) == 0 || list[0] != '[' || json.Unmarshal(list, &blocks) != nil {
		return nil, false
	}
	content := make([]any, len(blocks))
	size := 2 + len(blocks) - 1
	for i, b := range blocks {
		text, ok := plainText(b)
		if !ok {
			return nil, false
		}
		canonical := map[string]any{"type": "text", "text": text}
		enc, _ := json.Marshal(canonical)
		size += len(enc)
		// Empty blocks add no text but would inflate the request without bound.
		if size > budget {
			return nil, false
		}
		content[i] = canonical
	}
	return content, true
}

// inspectable reports whether any text block of the result carries non-blank text.
func inspectable(result map[string]any) bool {
	blocks, _ := result["content"].([]any)
	for _, b := range blocks {
		if block, ok := b.(map[string]any); ok {
			if text, _ := block["text"].(string); strings.TrimSpace(text) != "" {
				return true
			}
		}
	}
	return false
}

// plainText returns the text of a block that has exactly the keys type="text" and a
// string text.
func plainText(b json.RawMessage) (string, bool) {
	var fields map[string]json.RawMessage
	var typ string
	var text *string
	if json.Unmarshal(b, &fields) != nil || len(fields) != 2 ||
		json.Unmarshal(fields["type"], &typ) != nil || typ != "text" ||
		json.Unmarshal(fields["text"], &text) != nil || text == nil {
		return "", false
	}
	return *text, true
}

// decodeNumbers decodes a JSON document keeping numbers exactly as written.
func decodeNumbers(raw []byte, out any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	return dec.Decode(out)
}

// structuredProbe returns the text listing the keys and values of structuredContent.
// There is no probe when structuredContent holds nothing to list or when content is
// not an array the probe can join.
func structuredProbe(result map[string]any) (string, bool) {
	var parts []string
	if sc := result["structuredContent"]; sc != nil {
		parts = collectParts(sc, nil)
	}
	if len(parts) == 0 {
		return "", false
	}
	switch result["content"].(type) {
	case nil, []any:
	default:
		return "", false
	}
	return strings.Join(parts, "\n"), true
}

func collectParts(value any, acc []string) []string {
	switch v := value.(type) {
	case string:
		if strings.TrimSpace(v) != "" {
			acc = append(acc, v)
		}
	case map[string]any:
		keys := make([]string, 0, len(v))
		for k := range v {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if strings.TrimSpace(k) != "" {
				acc = append(acc, k)
			}
			acc = collectParts(v[k], acc)
		}
	case []any:
		for _, item := range v {
			acc = collectParts(item, acc)
		}
	case nil:
		acc = append(acc, "null")
	case bool:
		acc = append(acc, strconv.FormatBool(v))
	case json.Number:
		acc = append(acc, v.String())
	}
	return acc
}
