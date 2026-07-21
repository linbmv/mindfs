package api

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
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
