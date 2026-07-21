package update

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestParseReleaseNotesVersion(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		text string
		want string
	}{
		{name: "tag heading", text: "# MindFS v0.2.3\n\n## Fixes\n", want: "v0.2.3"},
		{name: "version without prefix", text: "# MindFS 0.2.3\n", want: "0.2.3"},
		{name: "invalid heading", text: "# Latest v0.2.3\n", want: ""},
		{name: "empty", text: "", want: ""},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := parseReleaseNotesVersion(tt.text)
			if got != tt.want {
				t.Fatalf("parseReleaseNotesVersion(%q) = %q, want %q", tt.text, got, tt.want)
			}
		})
	}
}

func TestLatestReleaseNotesBody(t *testing.T) {
	t.Parallel()

	text := "# MindFS v0.2.3\n\n## 优化和修复\n- latest\n\n# MindFS v0.2.2\n\n## 修复\n- old\n"
	want := "# MindFS v0.2.3\n\n## 优化和修复\n- latest"
	if got := latestReleaseNotesBody(text); got != want {
		t.Fatalf("latestReleaseNotesBody() = %q, want %q", got, want)
	}
}

func TestIsNewerVersion(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		latest  string
		current string
		want    bool
	}{
		{name: "higher patch", latest: "0.1.1", current: "0.1.0", want: true},
		{name: "lower patch", latest: "0.1.0", current: "0.1.1", want: false},
		{name: "same version", latest: "0.1.0", current: "0.1.0", want: false},
		{name: "prefixed tag", latest: "v0.2.0", current: "0.1.9", want: true},
		{name: "git describe current", latest: "0.1.0", current: "v0.1.0-2-gabc123", want: false},
		{name: "invalid current treated as older", latest: "0.1.0", current: "dev", want: true},
		{name: "invalid latest ignored", latest: "dev", current: "0.1.0", want: false},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := isNewerVersion(tt.latest, tt.current)
			if got != tt.want {
				t.Fatalf("isNewerVersion(%q, %q) = %t, want %t", tt.latest, tt.current, got, tt.want)
			}
		})
	}
}

func TestSafeUpdateScriptPathRequiresAbsoluteExecutableFile(t *testing.T) {
	t.Parallel()

	service := &Service{safeUpdateScript: "relative-script.sh"}
	if _, err := service.safeUpdateScriptPath(); err == nil {
		t.Fatal("safeUpdateScriptPath() accepted a relative path")
	}

	dir := t.TempDir()
	path := filepath.Join(dir, "safe-update.sh")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	service.safeUpdateScript = path
	if _, err := service.safeUpdateScriptPath(); err == nil {
		t.Fatal("safeUpdateScriptPath() accepted a non-executable file")
	}
	if err := os.Chmod(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if got, err := service.safeUpdateScriptPath(); err != nil {
		t.Fatalf("safeUpdateScriptPath() error = %v", err)
	} else if got != path {
		t.Fatalf("safeUpdateScriptPath() = %q, want %q", got, path)
	}
}

func TestExecuteSafeUpdateScriptUsesServerControlledEnvironment(t *testing.T) {
	dir := t.TempDir()
	outputPath := filepath.Join(dir, "output")
	scriptPath := filepath.Join(dir, "safe-update.sh")
	script := "#!/bin/sh\nprintf '%s\\n%s\\n' \"$MINDFS_SAFE_UPDATE_EXECUTABLE\" \"$MINDFS_SAFE_UPDATE_VERSION\" >\"$SAFE_UPDATE_TEST_OUTPUT\"\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SAFE_UPDATE_TEST_OUTPUT", outputPath)

	service := &Service{
		executable:       "/opt/mindfs/bin/mindfs",
		safeUpdateScript: scriptPath,
		status: Status{
			LatestVersion: "v1.2.3",
		},
	}
	if err := service.executeSafeUpdateScript(context.Background()); err != nil {
		t.Fatalf("executeSafeUpdateScript() error = %v", err)
	}
	payload, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(payload), "/opt/mindfs/bin/mindfs\nv1.2.3\n"; got != want {
		t.Fatalf("script environment = %q, want %q", got, want)
	}
}

func TestTriggerSafeUpdateWithoutScriptDoesNotFallBack(t *testing.T) {
	t.Parallel()

	service := &Service{
		status: Status{
			HasUpdate:     true,
			LatestVersion: "v1.2.3",
			Status:        "available",
		},
	}
	if err := service.TriggerSafeUpdate(context.Background()); err == nil {
		t.Fatal("TriggerSafeUpdate() error = nil, want missing-script error")
	}
	if got := service.GetStatus().Status; got != "available" {
		t.Fatalf("status = %q, want available", got)
	}
}

func TestRunSafeUpdateRestartsInstalledBinaryAfterScriptSuccess(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "safe-update.sh")
	markerPath := filepath.Join(dir, "script-ran")
	script := "#!/bin/sh\nprintf '%s\n' \"$MINDFS_SAFE_UPDATE_EXECUTABLE\" >\"" + markerPath + "\"\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}

	var restartCalls int32
	previousStartReplacementProcess := startReplacementProcess
	startReplacementProcess = func(currentPID int, exe string, args []string, stdout, stderr io.Writer, pkgDir, dstBin, dstAgents, dstTaskTemplate, dstWeb string) error {
		atomic.AddInt32(&restartCalls, 1)
		if exe != "/opt/mindfs/bin/mindfs" {
			t.Fatalf("restart exe = %q, want /opt/mindfs/bin/mindfs", exe)
		}
		if got, want := strings.Join(args, "\x00"), "-addr\x00127.0.0.1:57331\x00-foreground"; got != want {
			t.Fatalf("restart args = %q, want %q", got, want)
		}
		if pkgDir != "" {
			t.Fatalf("pkgDir = %q, want empty for safe update restart", pkgDir)
		}
		return nil
	}
	t.Cleanup(func() { startReplacementProcess = previousStartReplacementProcess })

	service := &Service{
		executable:       "/opt/mindfs/bin/mindfs",
		args:             []string{"-addr", "127.0.0.1:57331", "-foreground"},
		safeUpdateScript: scriptPath,
		status: Status{
			LatestVersion: "v1.2.3",
			Status:        "installing",
		},
	}
	service.runSafeUpdate(context.Background())

	if got := atomic.LoadInt32(&restartCalls); got != 1 {
		t.Fatalf("restart calls = %d, want 1", got)
	}
	if got := service.GetStatus().Status; got != "restarting" {
		t.Fatalf("status = %q, want restarting", got)
	}
	payload, err := os.ReadFile(markerPath)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(payload), "/opt/mindfs/bin/mindfs\n"; got != want {
		t.Fatalf("script payload = %q, want %q", got, want)
	}
}

func TestRunSafeUpdateFailureDoesNotRestartInstalledBinary(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "safe-update.sh")
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\necho boom >&2\nexit 7\n"), 0o700); err != nil {
		t.Fatal(err)
	}

	var restartCalls int32
	previousStartReplacementProcess := startReplacementProcess
	startReplacementProcess = func(int, string, []string, io.Writer, io.Writer, string, string, string, string, string) error {
		atomic.AddInt32(&restartCalls, 1)
		return errors.New("restart should not be called")
	}
	t.Cleanup(func() { startReplacementProcess = previousStartReplacementProcess })

	service := &Service{
		executable:       "/opt/mindfs/bin/mindfs",
		safeUpdateScript: scriptPath,
		status: Status{
			LatestVersion: "v1.2.3",
			Status:        "installing",
		},
	}
	service.runSafeUpdate(context.Background())

	if got := atomic.LoadInt32(&restartCalls); got != 0 {
		t.Fatalf("restart calls = %d, want 0", got)
	}
	st := service.GetStatus()
	if st.Status != "failed" {
		t.Fatalf("status = %q, want failed", st.Status)
	}
	if !strings.Contains(st.Message, "boom") {
		t.Fatalf("message = %q, want script failure output", st.Message)
	}
}

func TestFetchAndVerifyManifest(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	restoreReleasePublicKey(t, base64.StdEncoding.EncodeToString(publicKey))

	payload := []byte(`{"version":"v1.2.3","repo":"a9gent/mindfs","artifacts":[{"name":"mindfs_v1.2.3_linux_amd64.tar.gz","sha256":"` + strings.Repeat("a", 64) + `","size":123}]}` + "\n")
	body := signedManifestBody(t, payload, ed25519.Sign(privateKey, payload))
	manifestURL := "https://github.com/a9gent/mindfs/releases/download/v1.2.3/mindfs_v1.2.3_manifest.json"
	service := NewService("a9gent/mindfs", "v1.2.2", "/tmp/bin/mindfs", nil, time.Hour)
	service.client = &http.Client{Transport: staticTransport{
		manifestURL: body,
	}}

	manifest, err := service.fetchAndVerifyManifest(context.Background(), "v1.2.3")
	if err != nil {
		t.Fatalf("fetchAndVerifyManifest() error = %v", err)
	}
	if got := manifest.Artifacts[0].Name; got != "mindfs_v1.2.3_linux_amd64.tar.gz" {
		t.Fatalf("artifact name = %q", got)
	}
}

func TestFetchAndVerifyManifestRejectsBadSignature(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	restoreReleasePublicKey(t, base64.StdEncoding.EncodeToString(publicKey))

	payload := []byte(`{"version":"v1.2.3","artifacts":[]}` + "\n")
	body := signedManifestBody(t, payload, make([]byte, ed25519.SignatureSize))
	manifestURL := "https://github.com/a9gent/mindfs/releases/download/v1.2.3/mindfs_v1.2.3_manifest.json"
	service := NewService("a9gent/mindfs", "v1.2.2", "/tmp/bin/mindfs", nil, time.Hour)
	service.client = &http.Client{Transport: staticTransport{
		manifestURL: body,
	}}

	if _, err := service.fetchAndVerifyManifest(context.Background(), "v1.2.3"); err == nil {
		t.Fatal("fetchAndVerifyManifest() error = nil, want bad signature error")
	}
}

func TestVerifyFileSHA256(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "artifact.tar.gz")
	body := []byte("release artifact")
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(body)
	if err := verifyFileSHA256(path, hex.EncodeToString(sum[:]), int64(len(body))); err != nil {
		t.Fatalf("verifyFileSHA256() error = %v", err)
	}
	if err := verifyFileSHA256(path, strings.Repeat("0", 64), int64(len(body))); err == nil {
		t.Fatal("verifyFileSHA256() error = nil, want sha mismatch")
	}
}

func TestRelayAssetURL(t *testing.T) {
	name := "mindfs_v0.3.4_windows_amd64.zip"
	want := "https://relay.a9gent.com/mindfs-downloads/mindfs_v0.3.4_windows_amd64.zip"
	if got := relayAssetURL(name); got != want {
		t.Fatalf("relayAssetURL() = %q, want %q", got, want)
	}
	for _, name := range []string{"", "../mindfs.zip", `dir\mindfs.zip`} {
		if got := relayAssetURL(name); got != "" {
			t.Fatalf("relayAssetURL(%q) = %q, want empty", name, got)
		}
	}
}

func TestInstallLayoutInstalled(t *testing.T) {
	service := NewService("a9gent/mindfs", "v1.2.2", filepath.Join("opt", "mindfs", "bin", "mindfs"), nil, time.Hour)
	layout, err := service.installLayout()
	if err != nil {
		t.Fatalf("installLayout() error = %v", err)
	}
	if layout.Mode != "installed" {
		t.Fatalf("layout mode = %q, want installed", layout.Mode)
	}
	if got, want := filepath.Clean(layout.Prefix), filepath.Join("opt", "mindfs"); got != want {
		t.Fatalf("layout prefix = %q, want %q", got, want)
	}
	bin, agents, taskTemplate, web := layout.destinationPaths("mindfs")
	if got, want := bin, filepath.Join("opt", "mindfs", "bin", "mindfs"); got != want {
		t.Fatalf("bin path = %q, want %q", got, want)
	}
	if got, want := agents, filepath.Join("opt", "mindfs", "share", "mindfs", "agents.json"); got != want {
		t.Fatalf("agents path = %q, want %q", got, want)
	}
	if got, want := taskTemplate, filepath.Join("opt", "mindfs", "share", "mindfs", "task_template.json"); got != want {
		t.Fatalf("task template path = %q, want %q", got, want)
	}
	if got, want := web, filepath.Join("opt", "mindfs", "share", "mindfs", "web"); got != want {
		t.Fatalf("web path = %q, want %q", got, want)
	}
}

func TestInstallLayoutPortable(t *testing.T) {
	service := NewService("a9gent/mindfs", "v1.2.2", filepath.Join("tmp", "mindfs_v1.2.2_linux_amd64", "mindfs"), nil, time.Hour)
	layout, err := service.installLayout()
	if err != nil {
		t.Fatalf("installLayout() error = %v", err)
	}
	if layout.Mode != "portable" {
		t.Fatalf("layout mode = %q, want portable", layout.Mode)
	}
	if got, want := filepath.Clean(layout.ExeDir), filepath.Join("tmp", "mindfs_v1.2.2_linux_amd64"); got != want {
		t.Fatalf("layout exe dir = %q, want %q", got, want)
	}
	bin, agents, taskTemplate, web := layout.destinationPaths("mindfs")
	if got, want := bin, filepath.Join("tmp", "mindfs_v1.2.2_linux_amd64", "mindfs"); got != want {
		t.Fatalf("bin path = %q, want %q", got, want)
	}
	if got, want := agents, filepath.Join("tmp", "mindfs_v1.2.2_linux_amd64", "agents.json"); got != want {
		t.Fatalf("agents path = %q, want %q", got, want)
	}
	if got, want := taskTemplate, filepath.Join("tmp", "mindfs_v1.2.2_linux_amd64", "task_template.json"); got != want {
		t.Fatalf("task template path = %q, want %q", got, want)
	}
	if got, want := web, filepath.Join("tmp", "mindfs_v1.2.2_linux_amd64", "web"); got != want {
		t.Fatalf("web path = %q, want %q", got, want)
	}
}

func TestSafeArchiveTargetRejectsTraversal(t *testing.T) {
	root := t.TempDir()
	cases := []string{"../escape", "/tmp/escape", ".."}
	for _, name := range cases {
		if _, err := safeArchiveTarget(root, name); err == nil {
			t.Fatalf("safeArchiveTarget(%q) error = nil, want error", name)
		}
	}
	if target, err := safeArchiveTarget(root, "mindfs_v1.2.3/mindfs"); err != nil {
		t.Fatalf("safeArchiveTarget(valid) error = %v", err)
	} else if !stringsHasPrefix(target, root) {
		t.Fatalf("target %q does not stay under %q", target, root)
	}
}

func TestExtractTarGzRejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	archivePath := filepath.Join(dir, "bad.tar.gz")
	if err := writeTarGz(archivePath, "../escape", "bad"); err != nil {
		t.Fatal(err)
	}
	if err := extractTarGz(archivePath, filepath.Join(dir, "out")); err == nil {
		t.Fatal("extractTarGz() error = nil, want traversal error")
	}
}

func TestExtractZipRejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	archivePath := filepath.Join(dir, "bad.zip")
	if err := writeZip(archivePath, "../escape", "bad"); err != nil {
		t.Fatal(err)
	}
	if err := extractZip(archivePath, filepath.Join(dir, "out")); err == nil {
		t.Fatal("extractZip() error = nil, want traversal error")
	}
}

func restoreReleasePublicKey(t *testing.T, value string) {
	t.Helper()
	old := releaseManifestPublicKey
	releaseManifestPublicKey = value
	t.Cleanup(func() {
		releaseManifestPublicKey = old
	})
}

func signedManifestBody(t *testing.T, payload, signature []byte) []byte {
	t.Helper()
	body, err := json.Marshal(map[string]string{
		"payload":   base64.StdEncoding.EncodeToString(payload),
		"signature": base64.StdEncoding.EncodeToString(signature),
	})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

type staticTransport map[string][]byte

func (t staticTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	body, ok := t[req.URL.String()]
	if !ok {
		return &http.Response{
			StatusCode: http.StatusNotFound,
			Status:     "404 Not Found",
			Body:       io.NopCloser(bytes.NewReader(nil)),
			Header:     make(http.Header),
			Request:    req,
		}, nil
	}
	return &http.Response{
		StatusCode: http.StatusOK,
		Status:     "200 OK",
		Body:       io.NopCloser(bytes.NewReader(body)),
		Header:     make(http.Header),
		Request:    req,
	}, nil
}

func writeTarGz(path, name, content string) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	gzw := gzip.NewWriter(file)
	defer gzw.Close()
	tw := tar.NewWriter(gzw)
	defer tw.Close()
	body := []byte(content)
	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(body)), Typeflag: tar.TypeReg}); err != nil {
		return err
	}
	_, err = tw.Write(body)
	return err
}

func writeZip(path, name, content string) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	zw := zip.NewWriter(file)
	defer zw.Close()
	writer, err := zw.Create(name)
	if err != nil {
		return err
	}
	_, err = writer.Write([]byte(content))
	return err
}

func stringsHasPrefix(value, prefix string) bool {
	rel, err := filepath.Rel(prefix, value)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}
