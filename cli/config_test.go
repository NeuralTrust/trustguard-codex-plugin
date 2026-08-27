package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestManagedModeLocksKeyFields(t *testing.T) {
	dir := t.TempDir()
	system := filepath.Join(dir, "system.json")
	user := filepath.Join(dir, "user.json")
	if err := os.WriteFile(system, []byte(`{"api_key":"tgk_managed","data_url":"https://managed.example","fail_mode":"closed"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(user, []byte(`{"api_key":"tgk_user","data_url":"https://user.example","fail_mode":"open","timeout_ms":1234}`), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Setenv("TRUSTGUARD_CODEX_SYSTEM_CONFIG", system)
	t.Setenv("TRUSTGUARD_CODEX_CONFIG", user)
	t.Setenv("TRUSTGUARD_API_KEY", "tgk_env")
	t.Setenv("TRUSTGUARD_DATA_URL", "https://env.example")
	t.Setenv("TRUSTGUARD_FAIL_MODE", "open")

	cfg := loadConfig()
	if !cfg.managed {
		t.Fatal("expected managed mode")
	}
	if cfg.APIKey != "tgk_managed" || cfg.DataURL != "https://managed.example" || cfg.FailMode != "closed" {
		t.Fatalf("locked fields overridden: %+v", cfg)
	}
	if cfg.TimeoutMS != 1234 {
		t.Fatalf("soft pref timeout_ms not applied, got %d", cfg.TimeoutMS)
	}
}

func TestConsumerIDForReadsAuthJSON(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	tok := unsignedJWT(`{"email":"joan@acme.com"}`)
	body := `{"tokens":{"id_token":"` + tok + `"}}`
	if err := os.WriteFile(filepath.Join(home, "auth.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	got := consumerIDFor(Config{}, hookInput{})
	if got != "joan@acme.com" {
		t.Fatalf("got %q", got)
	}
}

func TestConsumerIDForHookEmailBeatsAuthJSON(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	tok := unsignedJWT(`{"email":"joan@acme.com"}`)
	body := `{"tokens":{"id_token":"` + tok + `"}}`
	if err := os.WriteFile(filepath.Join(home, "auth.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	got := consumerIDFor(Config{}, hookInput{UserEmail: "alice@acme.com"})
	if got != "alice@acme.com" {
		t.Fatalf("got %q", got)
	}
}

func TestConsumerIDForConfiguredBeatsAuthJSON(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	tok := unsignedJWT(`{"email":"joan@acme.com"}`)
	body := `{"tokens":{"id_token":"` + tok + `"}}`
	if err := os.WriteFile(filepath.Join(home, "auth.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	got := consumerIDFor(Config{ConsumerID: "codex:mdm"}, hookInput{UserEmail: "alice@acme.com"})
	if got != "codex:mdm" {
		t.Fatalf("got %q", got)
	}
}

func unsignedJWT(payload string) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`))
	body := base64.RawURLEncoding.EncodeToString([]byte(payload))
	return header + "." + body + ".x"
}
