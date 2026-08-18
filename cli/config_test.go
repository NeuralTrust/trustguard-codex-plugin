package main

import (
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
