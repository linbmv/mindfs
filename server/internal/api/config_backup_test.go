package api

import (
	"archive/tar"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigBackupDownloadArchivesChannelConfig(t *testing.T) {
	configHome := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configHome)
	configDir := filepath.Join(configHome, "mindfs")
	profileDir := filepath.Join(configDir, "agents-config", "codex-work")
	if err := os.MkdirAll(profileDir, 0o700); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		filepath.Join(configDir, "agents-config", "manifest.json"): `[{"id":"codex-work"}]`,
		filepath.Join(profileDir, "001-auth.json"):                 `{"token":"secret"}`,
		filepath.Join(configDir, "agents-env.json"):                `{"codex-work":["OPENAI_API_KEY=x"]}`,
		filepath.Join(configDir, "api-providers.json"):             `[]`,
	}
	for path, content := range files {
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	agentsPath := filepath.Join(t.TempDir(), "agents.json")
	if err := os.WriteFile(agentsPath, []byte(`{"agents":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MINDFS_AGENTS_CONFIG", agentsPath)

	h := &HTTPHandler{}
	req := httptest.NewRequest(http.MethodGet, "/api/config-backup/download", nil)
	rec := httptest.NewRecorder()
	h.handleConfigBackupDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/gzip" {
		t.Fatalf("content-type = %q", got)
	}
	if got := rec.Header().Get("Content-Disposition"); !strings.Contains(got, "mindfs-config-backup-") {
		t.Fatalf("content-disposition = %q", got)
	}

	gzr, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]string{}
	tr := tar.NewReader(gzr)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if header.Typeflag == tar.TypeDir {
			continue
		}
		content, err := io.ReadAll(tr)
		if err != nil {
			t.Fatal(err)
		}
		seen[header.Name] = string(content)
	}

	want := map[string]string{
		"config/agents-config/manifest.json":            `[{"id":"codex-work"}]`,
		"config/agents-config/codex-work/001-auth.json": `{"token":"secret"}`,
		"config/agents-env.json":                        `{"codex-work":["OPENAI_API_KEY=x"]}`,
		"config/api-providers.json":                     `[]`,
		"config/agents.json":                            `{"agents":[]}`,
	}
	for name, content := range want {
		if seen[name] != content {
			t.Fatalf("archive entry %q = %q, want %q (all: %v)", name, seen[name], content, keys(seen))
		}
	}
}

func TestConfigBackupDownloadSkipsMissingOptionalFiles(t *testing.T) {
	configHome := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configHome)
	agentsPath := filepath.Join(t.TempDir(), "agents.json")
	if err := os.WriteFile(agentsPath, []byte(`{"agents":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MINDFS_AGENTS_CONFIG", agentsPath)

	h := &HTTPHandler{}
	rec := httptest.NewRecorder()
	h.handleConfigBackupDownload(rec, httptest.NewRequest(http.MethodGet, "/api/config-backup/download", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	gzr, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(gzr)
	var names []string
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		names = append(names, header.Name)
	}
	if len(names) != 1 || names[0] != "config/agents.json" {
		t.Fatalf("archive entries = %v, want only config/agents.json", names)
	}
}

func keys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
