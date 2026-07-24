package api

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"mindfs/server/internal/agent"
)

func configurePortableAgentTest(t *testing.T) {
	t.Helper()
	configHome := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configHome)
	agentConfigPath := filepath.Join(t.TempDir(), "agents.json")
	payload := []byte(`{"agents":[{"name":"codex","command":"codex","protocol":"codex-sdk"}]}`)
	if err := os.WriteFile(agentConfigPath, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MINDFS_AGENTS_CONFIG", agentConfigPath)
}

func TestPortableAgentConfigRoundTripAndOverwrite(t *testing.T) {
	configurePortableAgentTest(t)
	bundle := portableAgentConfig{
		Version: portableAgentConfigVersion,
		Agent:   "codex",
		Name:    "work",
		Files: []portableAgentConfigFile{
			{SourcePath: "/home/user/.codex/auth.json", Content: "{\"token\":\"secret\"}\n"},
			{SourcePath: "/home/user/.codex/config.toml", Content: "model = \"gpt-test\"\n"},
		},
		EnvLines: []string{"OPENAI_API_KEY=test-key"},
	}

	entry, err := importAgentConfigBackup(bundle, false)
	if err != nil {
		t.Fatal(err)
	}
	if entry.ID != "codex-work" {
		t.Fatalf("entry id = %q, want codex-work", entry.ID)
	}
	exported, err := exportAgentConfigBackup(entry.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(exported, bundle) {
		t.Fatalf("exported bundle = %#v, want %#v", exported, bundle)
	}

	if _, err := importAgentConfigBackup(bundle, false); !errors.Is(err, errAgentConfigConflict) {
		t.Fatalf("duplicate import error = %v, want conflict", err)
	}
	bundle.Files[1].Content = "model = \"gpt-updated\"\n"
	if _, err := importAgentConfigBackup(bundle, true); err != nil {
		t.Fatal(err)
	}
	exported, err = exportAgentConfigBackup(entry.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got := exported.Files[1].Content; got != bundle.Files[1].Content {
		t.Fatalf("updated content = %q, want %q", got, bundle.Files[1].Content)
	}

	root, err := agentConfigRootDir()
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(root)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("config root mode = %o, want 700", got)
	}
	for _, source := range entry.Sources {
		path, err := safeAgentConfigBackupPath(root, source.BackupPath)
		if err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if got := info.Mode().Perm(); got != 0o600 {
			t.Fatalf("backup file mode = %o, want 600", got)
		}
	}
}

func TestPortableAgentConfigRejectsUnsafeInput(t *testing.T) {
	configurePortableAgentTest(t)
	base := portableAgentConfig{
		Version: portableAgentConfigVersion,
		Agent:   "codex",
		Name:    "work",
		Files:   []portableAgentConfigFile{{SourcePath: "relative/config.toml", Content: "test"}},
	}
	if _, err := importAgentConfigBackup(base, false); err == nil {
		t.Fatal("expected relative source path to be rejected")
	}
	if _, err := safeAgentConfigBackupPath(t.TempDir(), "../outside"); err == nil {
		t.Fatal("expected backup path traversal to be rejected")
	}
	base.Version = portableAgentConfigVersion + 1
	if _, err := importAgentConfigBackup(base, false); err == nil {
		t.Fatal("expected unsupported version to be rejected")
	}
}

func TestResolveAgentConfigSwitchSourcesUsesConfiguredTargets(t *testing.T) {
	entry := agentConfigManifestEntry{
		ID:    "codex-newoctopus",
		Agent: "codex",
		Sources: []agentConfigSource{
			{SourcePath: "/root/.codex/auth.json", BackupPath: "codex-newoctopus/001-auth.json"},
			{SourcePath: "/root/.codex/config_octopus.toml", BackupPath: "codex-newoctopus/002-config.toml"},
		},
	}
	def := agent.Definition{
		Name: "codex",
		ConfigBackup: agent.ConfigBackupDefaults{
			FileSources: []string{"~/.codex/auth.json", "~/.codex/config_anywolflh.toml"},
		},
	}

	resolved, err := resolveAgentConfigSwitchSources(entry, def)
	if err != nil {
		t.Fatalf("resolveAgentConfigSwitchSources returned error: %v", err)
	}
	if len(resolved) != 2 {
		t.Fatalf("resolved source count = %d, want 2", len(resolved))
	}
	if got := filepath.Base(resolved[0].SourcePath); got != "auth.json" {
		t.Fatalf("first target = %q, want auth.json", got)
	}
	if got := filepath.Base(resolved[1].SourcePath); got != "config.toml" {
		t.Fatalf("second target = %q, want config.toml", got)
	}
	if resolved[1].BackupPath != entry.Sources[1].BackupPath {
		t.Fatalf("second backup path = %q, want %q", resolved[1].BackupPath, entry.Sources[1].BackupPath)
	}
}

func TestResolveAgentConfigSwitchSourcesNormalizesGrokConfigPath(t *testing.T) {
	entry := agentConfigManifestEntry{
		ID:    "grok-linuxdo",
		Agent: "grok",
		Sources: []agentConfigSource{
			{SourcePath: "/root/.grok/config.json", BackupPath: "grok-linuxdo/001-config.json"},
			{SourcePath: "/root/.grok/auth.json", BackupPath: "grok-linuxdo/002-auth.json"},
		},
	}
	def := agent.Definition{
		Name: "grok",
		ConfigBackup: agent.ConfigBackupDefaults{
			// Intentionally wrong legacy defaults; normalization must still land on config.toml.
			FileSources: []string{"~/.grok/config.json", "~/.grok/auth.json"},
		},
	}

	resolved, err := resolveAgentConfigSwitchSources(entry, def)
	if err != nil {
		t.Fatalf("resolveAgentConfigSwitchSources returned error: %v", err)
	}
	if len(resolved) != 2 {
		t.Fatalf("resolved source count = %d, want 2", len(resolved))
	}
	if got := filepath.Base(resolved[0].SourcePath); got != "config.toml" {
		t.Fatalf("first target = %q, want config.toml", got)
	}
	if got := filepath.Base(resolved[1].SourcePath); got != "auth.json" {
		t.Fatalf("second target = %q, want auth.json", got)
	}
}

func TestNormalizeGrokSwitchEnvMapsLegacyBaseURL(t *testing.T) {
	got := normalizeGrokSwitchEnv(map[string]string{
		"XAI_API_KEY":            "sk-test",
		"GROK_XAI_API_BASE_URL":  "https://legacy.example/v1",
	})
	if got["GROK_MODELS_BASE_URL"] != "https://legacy.example/v1" {
		t.Fatalf("GROK_MODELS_BASE_URL = %q, want legacy value", got["GROK_MODELS_BASE_URL"])
	}
	if _, ok := got["GROK_XAI_API_BASE_URL"]; ok {
		t.Fatalf("legacy GROK_XAI_API_BASE_URL should be removed")
	}
	// Prefer the official key when both are present.
	got = normalizeGrokSwitchEnv(map[string]string{
		"GROK_MODELS_BASE_URL":  "https://official.example/v1",
		"GROK_XAI_API_BASE_URL": "https://legacy.example/v1",
	})
	if got["GROK_MODELS_BASE_URL"] != "https://official.example/v1" {
		t.Fatalf("GROK_MODELS_BASE_URL = %q, want official value", got["GROK_MODELS_BASE_URL"])
	}
}

func TestMergeGrokConfigFromEnvRewritesAPIKeyAndBaseURL(t *testing.T) {
	existing := `[models]
default = "grok-4.5"

[endpoints]
models_base_url = "http://old-provider/v1"

[model."grok-4.5"]
model = "grok-4.5"
name = "Grok 4.5"
api_key = "sk-old"
context_window = 1000000
`
	got := mergeGrokConfigFromEnv(existing, "sk-new", "https://new-provider/v1")
	if !strings.Contains(got, `models_base_url = "https://new-provider/v1"`) {
		t.Fatalf("base URL not updated:\n%s", got)
	}
	if strings.Contains(got, `models_base_url = "http://old-provider/v1"`) {
		t.Fatalf("old base URL still present:\n%s", got)
	}
	if !strings.Contains(got, `api_key = "sk-new"`) {
		t.Fatalf("api key not updated:\n%s", got)
	}
	if strings.Contains(got, `api_key = "sk-old"`) {
		t.Fatalf("old api key still present:\n%s", got)
	}
	// Non-credential fields must be preserved.
	if !strings.Contains(got, `context_window = 1000000`) {
		t.Fatalf("unrelated fields were dropped:\n%s", got)
	}
}

func TestMergeGrokConfigFromEnvCreatesMissingSections(t *testing.T) {
	got := mergeGrokConfigFromEnv("", "sk-fresh", "https://fresh.example/v1")
	if !strings.Contains(got, `[endpoints]`) || !strings.Contains(got, `models_base_url = "https://fresh.example/v1"`) {
		t.Fatalf("endpoints section missing:\n%s", got)
	}
	if !strings.Contains(got, `[model."grok-4.5"]`) || !strings.Contains(got, `api_key = "sk-fresh"`) {
		t.Fatalf("model section missing:\n%s", got)
	}
}

func TestApplyGrokConfigFromEnvWritesLiveConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	grokDir := filepath.Join(home, ".grok")
	if err := os.MkdirAll(grokDir, 0o755); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(grokDir, "config.toml")
	initial := `[endpoints]
models_base_url = "http://old/v1"

[model."grok-4.5"]
api_key = "sk-old"
`
	if err := os.WriteFile(configPath, []byte(initial), 0o600); err != nil {
		t.Fatal(err)
	}

	// Use the legacy env key name to prove migration still rewrites the live file.
	if err := applyGrokConfigFromEnv(map[string]string{
		"XAI_API_KEY":           "sk-linuxdo",
		"GROK_XAI_API_BASE_URL": "https://llmroutes.cloud/v1",
	}); err != nil {
		t.Fatalf("applyGrokConfigFromEnv: %v", err)
	}

	payload, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(payload)
	if !strings.Contains(text, `models_base_url = "https://llmroutes.cloud/v1"`) {
		t.Fatalf("live models_base_url not updated:\n%s", text)
	}
	if !strings.Contains(text, `api_key = "sk-linuxdo"`) {
		t.Fatalf("live api_key not updated:\n%s", text)
	}
	if strings.Contains(text, "sk-old") || strings.Contains(text, "http://old/v1") {
		t.Fatalf("old credentials still present:\n%s", text)
	}
}
