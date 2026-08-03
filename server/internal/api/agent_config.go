package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"mindfs/server/internal/agent"
	"mindfs/server/internal/apperr"
	configpkg "mindfs/server/internal/config"
	"mindfs/server/internal/preferences"
)

type agentConfigSource struct {
	SourcePath string `json:"sourcePath"`
	BackupPath string `json:"backupPath"`
}

type agentConfigManifestEntry struct {
	ID        string              `json:"id"`
	Agent     string              `json:"agent"`
	Name      string              `json:"name"`
	CreatedAt string              `json:"createdAt"`
	UpdatedAt string              `json:"updatedAt"`
	Sources   []agentConfigSource `json:"sources,omitempty"`
	EnvKeys   []string            `json:"envKeys,omitempty"`
}

type agentConfigBackupRequest struct {
	Agent       string   `json:"agent"`
	Name        string   `json:"name"`
	FileSources []string `json:"file_sources"`
	EnvLines    []string `json:"env_lines"`
	Overwrite   bool     `json:"overwrite"`
}

type agentConfigSwitchRequest struct {
	ID               string `json:"id"`
	ConfirmOverwrite bool   `json:"confirm_overwrite"`
}

type portableAgentConfigFile struct {
	SourcePath string `json:"sourcePath"`
	Content    string `json:"content"`
}

type portableAgentConfig struct {
	Version  int                       `json:"version"`
	Agent    string                    `json:"agent"`
	Name     string                    `json:"name"`
	Files    []portableAgentConfigFile `json:"files,omitempty"`
	EnvLines []string                  `json:"envLines,omitempty"`
}

type agentConfigImportRequest struct {
	Config    portableAgentConfig `json:"config"`
	Overwrite bool                `json:"overwrite"`
}

type agentRestartRequest struct {
	Agent string `json:"agent"`
}

var agentConfigNamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

const portableAgentConfigVersion = 1

func (h *HTTPHandler) handleAgentConfigDefaults(w http.ResponseWriter, r *http.Request) {
	agentName := strings.TrimSpace(r.URL.Query().Get("agent"))
	if agentName == "" {
		respondError(w, http.StatusBadRequest, errInvalidRequest("agent required"))
		return
	}
	cfg, err := agent.LoadConfig("")
	if err != nil {
		respondError(w, http.StatusServiceUnavailable, err)
		return
	}
	def, ok := cfg.GetAgent(agentName)
	if !ok {
		respondError(w, http.StatusNotFound, errInvalidRequest("agent not configured"))
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{
		"agent":        def.Name,
		"file_sources": existingDefaultFileSources(def.ConfigBackup.FileSources),
		"env_keys":     def.ConfigBackup.EnvKeys,
	})
}

func (h *HTTPHandler) handleAgentConfigBackupsList(w http.ResponseWriter, r *http.Request) {
	agentName := strings.TrimSpace(r.URL.Query().Get("agent"))
	manifest, err := readAgentConfigManifest()
	if err != nil {
		respondError(w, http.StatusServiceUnavailable, err)
		return
	}
	if agentName == "" {
		respondJSON(w, http.StatusOK, manifest)
		return
	}
	filtered := make([]agentConfigManifestEntry, 0, len(manifest))
	for _, item := range manifest {
		if item.Agent == agentName {
			filtered = append(filtered, item)
		}
	}
	respondJSON(w, http.StatusOK, filtered)
}

func (h *HTTPHandler) handleAgentConfigBackupCreate(w http.ResponseWriter, r *http.Request) {
	var req agentConfigBackupRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxUploadRequestBytes)).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, errInvalidRequest("invalid request body"))
		return
	}
	entry, err := createAgentConfigBackup(req)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errAgentConfigConflict) {
			status = http.StatusConflict
		}
		respondError(w, status, err)
		return
	}
	respondJSON(w, http.StatusOK, entry)
}

func (h *HTTPHandler) handleAgentConfigBackupDelete(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		respondError(w, http.StatusBadRequest, errInvalidRequest("backup id required"))
		return
	}
	manifest, err := deleteAgentConfigBackup(id)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{"deleted": true, "id": id, "backups": manifest})
}

func (h *HTTPHandler) handleAgentConfigExport(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		respondError(w, http.StatusBadRequest, errInvalidRequest("backup id required"))
		return
	}
	bundle, err := exportAgentConfigBackup(id)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	respondJSON(w, http.StatusOK, bundle)
}

func (h *HTTPHandler) handleAgentConfigImport(w http.ResponseWriter, r *http.Request) {
	var req agentConfigImportRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxUploadRequestBytes)).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, errInvalidRequest("invalid request body"))
		return
	}
	entry, err := importAgentConfigBackup(req.Config, req.Overwrite)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errAgentConfigConflict) {
			status = http.StatusConflict
		}
		respondError(w, status, err)
		return
	}
	respondJSON(w, http.StatusOK, entry)
}

func (h *HTTPHandler) handleAgentConfigSwitch(w http.ResponseWriter, r *http.Request) {
	var req agentConfigSwitchRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxUploadRequestBytes)).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, errInvalidRequest("invalid request body"))
		return
	}
	entry, needsConfirm, err := switchAgentConfig(req, h.AppContext)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	if needsConfirm {
		respondJSON(w, http.StatusOK, map[string]any{
			"needs_confirm": true,
			"message":       "目标配置文件已存在，请确保已备份",
			"backup":        entry,
		})
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{
		"needs_confirm": false,
		"backup":        entry,
	})
}

func (h *HTTPHandler) handleAgentRestart(w http.ResponseWriter, r *http.Request) {
	var req agentRestartRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxUploadRequestBytes)).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, errInvalidRequest("invalid request body"))
		return
	}
	if err := restartAgent(req.Agent, h.AppContext); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{
		"restarting": true,
		"agent":      strings.TrimSpace(req.Agent),
	})
}

var errAgentConfigConflict = errors.New("backup already exists")

func createAgentConfigBackup(req agentConfigBackupRequest) (agentConfigManifestEntry, error) {
	agentName, backupName, id, err := normalizeAgentConfigRequest(req.Agent, req.Name)
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	cfg, err := agent.LoadConfig("")
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	if _, ok := cfg.GetAgent(agentName); !ok {
		return agentConfigManifestEntry{}, fmt.Errorf("agent not configured: %s", agentName)
	}
	configRoot, err := agentConfigRootDir()
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	manifest, err := readAgentConfigManifest()
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	existingIndex := -1
	var createdAt string
	for index, item := range manifest {
		if item.ID == id {
			if !req.Overwrite {
				return agentConfigManifestEntry{}, errAgentConfigConflict
			}
			existingIndex = index
			createdAt = item.CreatedAt
			break
		}
	}
	now := time.Now().Format(time.RFC3339)
	if createdAt == "" {
		createdAt = now
	}
	entry := agentConfigManifestEntry{
		ID:        id,
		Agent:     agentName,
		Name:      backupName,
		CreatedAt: createdAt,
		UpdatedAt: now,
	}
	sources, err := normalizeFileSources(req.FileSources)
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	envLines, envKeys, err := normalizeEnvLines(req.EnvLines)
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	if len(sources) == 0 && len(envLines) == 0 {
		return agentConfigManifestEntry{}, errors.New("config source or environment variables required")
	}
	if err := os.RemoveAll(filepath.Join(configRoot, id)); err != nil {
		return agentConfigManifestEntry{}, apperr.Wrap("remove", filepath.Join(configRoot, id), err)
	}
	for index, source := range sources {
		name := fmt.Sprintf("%03d-%s", index+1, filepath.Base(source))
		rel := filepath.Join(id, name)
		dst := filepath.Join(configRoot, rel)
		if err := copyFile(source, dst); err != nil {
			return agentConfigManifestEntry{}, err
		}
		entry.Sources = append(entry.Sources, agentConfigSource{
			SourcePath: source,
			BackupPath: filepath.ToSlash(rel),
		})
	}
	envMap, err := readAgentEnvBackups()
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	if len(envLines) > 0 {
		envMap[id] = envLines
		entry.EnvKeys = envKeys
	} else {
		delete(envMap, id)
	}
	if err := writeAgentEnvBackups(envMap); err != nil {
		return agentConfigManifestEntry{}, err
	}
	if err := updateAgentConfigDefaults(agentName, sources, envKeys); err != nil {
		return agentConfigManifestEntry{}, err
	}
	if existingIndex >= 0 {
		manifest[existingIndex] = entry
	} else {
		manifest = append(manifest, entry)
	}
	if err := writeAgentConfigManifest(manifest); err != nil {
		return agentConfigManifestEntry{}, err
	}
	return entry, nil
}

func deleteAgentConfigBackup(id string) ([]agentConfigManifestEntry, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return nil, errors.New("backup id required")
	}
	manifest, err := readAgentConfigManifest()
	if err != nil {
		return nil, err
	}
	next := make([]agentConfigManifestEntry, 0, len(manifest))
	found := false
	for _, item := range manifest {
		if item.ID == id {
			found = true
			continue
		}
		next = append(next, item)
	}
	if !found {
		return nil, errors.New("backup not found")
	}
	if err := writeAgentConfigManifest(next); err != nil {
		return nil, err
	}
	configRoot, err := agentConfigRootDir()
	if err != nil {
		return nil, err
	}
	if err := os.RemoveAll(filepath.Join(configRoot, id)); err != nil {
		return nil, apperr.Wrap("remove", filepath.Join(configRoot, id), err)
	}
	envBackups, err := readAgentEnvBackups()
	if err != nil {
		return nil, err
	}
	if _, ok := envBackups[id]; ok {
		delete(envBackups, id)
		if err := writeAgentEnvBackups(envBackups); err != nil {
			return nil, err
		}
	}
	return next, nil
}

func exportAgentConfigBackup(id string) (portableAgentConfig, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return portableAgentConfig{}, errors.New("backup id required")
	}
	manifest, err := readAgentConfigManifest()
	if err != nil {
		return portableAgentConfig{}, err
	}
	var entry agentConfigManifestEntry
	for _, item := range manifest {
		if item.ID == id {
			entry = item
			break
		}
	}
	if entry.ID == "" {
		return portableAgentConfig{}, errors.New("backup not found")
	}
	configRoot, err := agentConfigRootDir()
	if err != nil {
		return portableAgentConfig{}, err
	}
	bundle := portableAgentConfig{
		Version: portableAgentConfigVersion,
		Agent:   entry.Agent,
		Name:    entry.Name,
	}
	totalSize := 0
	for _, source := range entry.Sources {
		path, err := safeAgentConfigBackupPath(configRoot, source.BackupPath)
		if err != nil {
			return portableAgentConfig{}, err
		}
		payload, err := os.ReadFile(path)
		if err != nil {
			return portableAgentConfig{}, apperr.Wrap("read", path, err)
		}
		if !utf8.Valid(payload) {
			return portableAgentConfig{}, fmt.Errorf("config file is not UTF-8 text: %s", source.SourcePath)
		}
		totalSize += len(payload)
		if totalSize > maxUploadRequestBytes {
			return portableAgentConfig{}, errors.New("exported config is too large")
		}
		bundle.Files = append(bundle.Files, portableAgentConfigFile{
			SourcePath: source.SourcePath,
			Content:    string(payload),
		})
	}
	envBackups, err := readAgentEnvBackups()
	if err != nil {
		return portableAgentConfig{}, err
	}
	bundle.EnvLines = append([]string(nil), envBackups[id]...)
	return bundle, nil
}

func importAgentConfigBackup(bundle portableAgentConfig, overwrite bool) (entry agentConfigManifestEntry, err error) {
	if bundle.Version != portableAgentConfigVersion {
		return agentConfigManifestEntry{}, fmt.Errorf("unsupported config export version: %d", bundle.Version)
	}
	agentName, backupName, id, err := normalizeAgentConfigRequest(bundle.Agent, bundle.Name)
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	cfg, err := agent.LoadConfig("")
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	if _, ok := cfg.GetAgent(agentName); !ok {
		return agentConfigManifestEntry{}, fmt.Errorf("agent not configured: %s", agentName)
	}

	manifest, err := readAgentConfigManifest()
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	existingIndex := -1
	createdAt := ""
	for index, item := range manifest {
		if item.ID != id {
			continue
		}
		if !overwrite {
			return agentConfigManifestEntry{}, errAgentConfigConflict
		}
		existingIndex = index
		createdAt = item.CreatedAt
		break
	}

	type importedFile struct {
		sourcePath string
		content    string
		name       string
	}
	files := make([]importedFile, 0, len(bundle.Files))
	seenSources := map[string]bool{}
	totalSize := 0
	for _, file := range bundle.Files {
		sourcePath, err := expandUserPath(file.SourcePath)
		if err != nil {
			return agentConfigManifestEntry{}, err
		}
		if sourcePath == "" || !filepath.IsAbs(sourcePath) {
			return agentConfigManifestEntry{}, fmt.Errorf("config source path must be absolute: %s", file.SourcePath)
		}
		if seenSources[sourcePath] {
			return agentConfigManifestEntry{}, fmt.Errorf("duplicate config source path: %s", sourcePath)
		}
		name := filepath.Base(sourcePath)
		if name == "." || name == string(filepath.Separator) || name == "" {
			return agentConfigManifestEntry{}, fmt.Errorf("invalid config source path: %s", sourcePath)
		}
		totalSize += len(file.Content)
		if totalSize > maxUploadRequestBytes {
			return agentConfigManifestEntry{}, errors.New("imported config is too large")
		}
		seenSources[sourcePath] = true
		files = append(files, importedFile{sourcePath: sourcePath, content: file.Content, name: name})
	}
	envLines, envKeys, err := normalizeEnvLines(bundle.EnvLines)
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	if len(files) == 0 && len(envLines) == 0 {
		return agentConfigManifestEntry{}, errors.New("config file or environment variables required")
	}

	configRoot, err := agentConfigRootDir()
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	if err := os.MkdirAll(configRoot, 0o700); err != nil {
		return agentConfigManifestEntry{}, apperr.Wrap("mkdir", configRoot, err)
	}
	if err := os.Chmod(configRoot, 0o700); err != nil {
		return agentConfigManifestEntry{}, apperr.Wrap("chmod", configRoot, err)
	}
	stageDir, err := os.MkdirTemp(configRoot, ".import-"+id+"-")
	if err != nil {
		return agentConfigManifestEntry{}, apperr.Wrap("mkdir", configRoot, err)
	}
	defer func() {
		if stageDir != "" {
			_ = os.RemoveAll(stageDir)
		}
	}()
	if err := os.Chmod(stageDir, 0o700); err != nil {
		return agentConfigManifestEntry{}, apperr.Wrap("chmod", stageDir, err)
	}

	now := time.Now().Format(time.RFC3339)
	if createdAt == "" {
		createdAt = now
	}
	entry = agentConfigManifestEntry{
		ID:        id,
		Agent:     agentName,
		Name:      backupName,
		CreatedAt: createdAt,
		UpdatedAt: now,
		EnvKeys:   envKeys,
	}
	for index, file := range files {
		name := fmt.Sprintf("%03d-%s", index+1, file.name)
		if err := os.WriteFile(filepath.Join(stageDir, name), []byte(file.content), 0o600); err != nil {
			return agentConfigManifestEntry{}, apperr.Wrap("write", filepath.Join(stageDir, name), err)
		}
		entry.Sources = append(entry.Sources, agentConfigSource{
			SourcePath: file.sourcePath,
			BackupPath: filepath.ToSlash(filepath.Join(id, name)),
		})
	}

	finalDir := filepath.Join(configRoot, id)
	previousDir := ""
	if _, statErr := os.Stat(finalDir); statErr == nil {
		previousDir, err = os.MkdirTemp(configRoot, ".previous-"+id+"-")
		if err != nil {
			return agentConfigManifestEntry{}, apperr.Wrap("mkdir", configRoot, err)
		}
		if err := os.Remove(previousDir); err != nil {
			return agentConfigManifestEntry{}, apperr.Wrap("remove", previousDir, err)
		}
		if err := os.Rename(finalDir, previousDir); err != nil {
			return agentConfigManifestEntry{}, apperr.Wrap("rename", finalDir, err)
		}
	} else if !os.IsNotExist(statErr) {
		return agentConfigManifestEntry{}, apperr.Wrap("stat", finalDir, statErr)
	}
	rollbackDir := true
	defer func() {
		if !rollbackDir {
			return
		}
		_ = os.RemoveAll(finalDir)
		if previousDir != "" {
			_ = os.Rename(previousDir, finalDir)
		}
	}()
	if err := os.Rename(stageDir, finalDir); err != nil {
		return agentConfigManifestEntry{}, apperr.Wrap("rename", stageDir, err)
	}
	stageDir = ""

	envBackups, err := readAgentEnvBackups()
	if err != nil {
		return agentConfigManifestEntry{}, err
	}
	previousEnvLines, hadPreviousEnv := envBackups[id]
	if len(envLines) > 0 {
		envBackups[id] = envLines
	} else {
		delete(envBackups, id)
	}
	if err := writeAgentEnvBackups(envBackups); err != nil {
		return agentConfigManifestEntry{}, err
	}
	rollbackEnv := true
	defer func() {
		if !rollbackEnv {
			return
		}
		if hadPreviousEnv {
			envBackups[id] = previousEnvLines
		} else {
			delete(envBackups, id)
		}
		_ = writeAgentEnvBackups(envBackups)
	}()

	if existingIndex >= 0 {
		manifest[existingIndex] = entry
	} else {
		manifest = append(manifest, entry)
	}
	if err := writeAgentConfigManifest(manifest); err != nil {
		return agentConfigManifestEntry{}, err
	}
	rollbackEnv = false
	rollbackDir = false
	if previousDir != "" {
		_ = os.RemoveAll(previousDir)
	}
	return entry, nil
}

func safeAgentConfigBackupPath(configRoot, relativePath string) (string, error) {
	cleanRoot := filepath.Clean(configRoot)
	path := filepath.Clean(filepath.Join(cleanRoot, filepath.FromSlash(relativePath)))
	relative, err := filepath.Rel(cleanRoot, path)
	if err != nil {
		return "", err
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", errors.New("invalid config backup path")
	}
	return path, nil
}

// resolveAgentConfigSwitchSources maps portable/profile source entries to the
// paths the currently configured Agent actually reads. An exported profile may
// contain a machine-specific filename such as config_octopus.toml, while the
// Codex runtime still reads ~/.codex/config.toml. The configured defaults are
// ordered to match the backup file list and are therefore the authoritative
// restore targets.
func resolveAgentConfigSwitchSources(entry agentConfigManifestEntry, def agent.Definition) ([]agentConfigSource, error) {
	resolved := make([]agentConfigSource, 0, len(entry.Sources))
	seen := make(map[string]struct{}, len(entry.Sources))
	for index, source := range entry.Sources {
		rawPath := strings.TrimSpace(source.SourcePath)
		if index < len(def.ConfigBackup.FileSources) && strings.TrimSpace(def.ConfigBackup.FileSources[index]) != "" {
			rawPath = strings.TrimSpace(def.ConfigBackup.FileSources[index])
		}
		rawPath = normalizeAgentConfigSwitchPath(entry.Agent, rawPath)
		sourcePath, err := expandUserPath(rawPath)
		if err != nil {
			return nil, err
		}
		sourcePath = filepath.Clean(strings.TrimSpace(sourcePath))
		if sourcePath == "" || !filepath.IsAbs(sourcePath) {
			return nil, fmt.Errorf("config source path must be absolute: %s", rawPath)
		}
		if _, exists := seen[sourcePath]; exists {
			return nil, fmt.Errorf("duplicate config switch target: %s", sourcePath)
		}
		seen[sourcePath] = struct{}{}
		resolved = append(resolved, agentConfigSource{
			SourcePath: sourcePath,
			BackupPath: source.BackupPath,
		})
	}
	return resolved, nil
}

// normalizeAgentConfigSwitchPath remaps profile/exported paths onto the files
// each agent runtime actually loads. Older custom definitions often recorded
// alternate filenames (config_octopus.toml, config.json) that made a switch
// appear successful while leaving the live configuration unchanged.
func normalizeAgentConfigSwitchPath(agentName, rawPath string) string {
	agentName = strings.ToLower(strings.TrimSpace(agentName))
	rawPath = strings.TrimSpace(rawPath)
	base := strings.ToLower(filepath.Base(rawPath))
	switch agentName {
	case "codex":
		// Codex always reads its user configuration from config.toml.
		if strings.HasSuffix(base, ".toml") {
			return "~/.codex/config.toml"
		}
	case "grok":
		// Grok CLI reads ~/.grok/config.toml. Older MindFS definitions used
		// config.json, so switching only touched a file the CLI never loads.
		if base == "config.json" || base == "config.toml" || strings.HasSuffix(base, ".toml") {
			return "~/.grok/config.toml"
		}
	}
	return rawPath
}

// normalizeGrokSwitchEnv maps legacy MindFS Grok env keys onto the names the
// CLI actually honors. GROK_XAI_API_BASE_URL was never a Grok official variable;
// GROK_MODELS_BASE_URL is the documented override for models_base_url.
func normalizeGrokSwitchEnv(env map[string]string) map[string]string {
	if len(env) == 0 {
		return env
	}
	out := cloneStringMap(env)
	if out == nil {
		out = map[string]string{}
	}
	if _, ok := out["GROK_MODELS_BASE_URL"]; !ok {
		if legacy := strings.TrimSpace(out["GROK_XAI_API_BASE_URL"]); legacy != "" {
			out["GROK_MODELS_BASE_URL"] = legacy
		}
	}
	delete(out, "GROK_XAI_API_BASE_URL")
	return out
}

// applyGrokConfigFromEnv writes the selected backup credentials into the live
// Grok config.toml. Per-model api_key in that file outranks XAI_API_KEY, so an
// env-only switch would leave the CLI on the previous provider.
func applyGrokConfigFromEnv(env map[string]string) error {
	env = normalizeGrokSwitchEnv(env)
	apiKey := strings.TrimSpace(env["XAI_API_KEY"])
	baseURL := strings.TrimSpace(env["GROK_MODELS_BASE_URL"])
	if apiKey == "" && baseURL == "" {
		return nil
	}
	configPath, err := expandUserPath("~/.grok/config.toml")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		return apperr.Wrap("mkdir", filepath.Dir(configPath), err)
	}
	existing, err := os.ReadFile(configPath)
	if err != nil && !os.IsNotExist(err) {
		return apperr.Wrap("read", configPath, err)
	}
	updated := mergeGrokConfigFromEnv(string(existing), apiKey, baseURL)
	return apperr.Wrap("write", configPath, os.WriteFile(configPath, []byte(updated), 0o600))
}

func mergeGrokConfigFromEnv(existing, apiKey, baseURL string) string {
	text := strings.ReplaceAll(existing, "\r\n", "\n")
	if strings.TrimSpace(text) == "" {
		var b strings.Builder
		if baseURL != "" {
			b.WriteString("[endpoints]\n")
			b.WriteString(fmt.Sprintf("models_base_url = %q\n", baseURL))
		}
		if apiKey != "" {
			if b.Len() > 0 {
				b.WriteString("\n")
			}
			b.WriteString("[model.\"grok-4.5\"]\n")
			b.WriteString("model = \"grok-4.5\"\n")
			b.WriteString("name = \"Grok 4.5\"\n")
			b.WriteString(fmt.Sprintf("api_key = %q\n", apiKey))
		}
		return b.String()
	}

	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines)+8)
	currentTable := ""
	hasEndpoints := false
	endpointsHasBaseURL := false
	modelTablesWithAPIKey := map[string]bool{}
	modelTablesSeen := map[string]bool{}

	// First pass: rewrite known keys in place and track which tables exist.
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			currentTable = trimmed
			if currentTable == "[endpoints]" {
				hasEndpoints = true
			}
			if isGrokModelTable(currentTable) {
				modelTablesSeen[currentTable] = true
			}
			out = append(out, line)
			continue
		}
		if currentTable == "[endpoints]" && baseURL != "" && isTOMLKeyAssignment(trimmed, "models_base_url") {
			out = append(out, fmt.Sprintf("models_base_url = %q", baseURL))
			endpointsHasBaseURL = true
			continue
		}
		if isGrokModelTable(currentTable) && apiKey != "" && isTOMLKeyAssignment(trimmed, "api_key") {
			out = append(out, fmt.Sprintf("api_key = %q", apiKey))
			modelTablesWithAPIKey[currentTable] = true
			continue
		}
		if currentTable == "[endpoints]" && isTOMLKeyAssignment(trimmed, "models_base_url") {
			endpointsHasBaseURL = true
		}
		if isGrokModelTable(currentTable) && isTOMLKeyAssignment(trimmed, "api_key") {
			modelTablesWithAPIKey[currentTable] = true
		}
		out = append(out, line)
	}

	// Second pass: inject missing keys into existing tables.
	if baseURL != "" && hasEndpoints && !endpointsHasBaseURL {
		out = injectKeyIntoTOMLTable(out, "[endpoints]", fmt.Sprintf("models_base_url = %q", baseURL))
		endpointsHasBaseURL = true
	}
	if apiKey != "" {
		for table := range modelTablesSeen {
			if !modelTablesWithAPIKey[table] {
				out = injectKeyIntoTOMLTable(out, table, fmt.Sprintf("api_key = %q", apiKey))
				modelTablesWithAPIKey[table] = true
			}
		}
	}

	// Append sections that did not exist at all.
	result := strings.Join(out, "\n")
	result = strings.TrimRight(result, "\n")
	if baseURL != "" && !hasEndpoints {
		if result != "" {
			result += "\n\n"
		}
		result += "[endpoints]\n" + fmt.Sprintf("models_base_url = %q", baseURL)
	}
	if apiKey != "" && len(modelTablesSeen) == 0 {
		if result != "" {
			result += "\n\n"
		}
		result += "[model.\"grok-4.5\"]\nmodel = \"grok-4.5\"\nname = \"Grok 4.5\"\n" + fmt.Sprintf("api_key = %q", apiKey)
	}
	if !strings.HasSuffix(result, "\n") {
		result += "\n"
	}
	return result
}

func isGrokModelTable(table string) bool {
	table = strings.TrimSpace(table)
	if !strings.HasPrefix(table, "[") || !strings.HasSuffix(table, "]") {
		return false
	}
	inner := strings.TrimSpace(table[1 : len(table)-1])
	return strings.HasPrefix(inner, "model.")
}

func isTOMLKeyAssignment(line, key string) bool {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return false
	}
	if !strings.HasPrefix(line, key) {
		return false
	}
	rest := strings.TrimSpace(line[len(key):])
	return strings.HasPrefix(rest, "=")
}

func injectKeyIntoTOMLTable(lines []string, tableHeader, assignment string) []string {
	out := make([]string, 0, len(lines)+1)
	inTable := false
	injected := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			if inTable && !injected {
				out = append(out, assignment)
				injected = true
			}
			inTable = trimmed == tableHeader
			out = append(out, line)
			continue
		}
		out = append(out, line)
		if i == len(lines)-1 && inTable && !injected {
			out = append(out, assignment)
			injected = true
		}
	}
	if inTable && !injected {
		out = append(out, assignment)
	}
	return out
}

func switchAgentConfig(req agentConfigSwitchRequest, app *AppContext) (agentConfigManifestEntry, bool, error) {
	id := strings.TrimSpace(req.ID)
	if id == "" {
		return agentConfigManifestEntry{}, false, errors.New("backup id required")
	}
	manifest, err := readAgentConfigManifest()
	if err != nil {
		return agentConfigManifestEntry{}, false, err
	}
	var entry agentConfigManifestEntry
	for _, item := range manifest {
		if item.ID == id {
			entry = item
			break
		}
	}
	if entry.ID == "" {
		return agentConfigManifestEntry{}, false, errors.New("backup not found")
	}
	if len(entry.Sources) == 0 && len(entry.EnvKeys) == 0 {
		return agentConfigManifestEntry{}, false, errors.New("backup has no config content")
	}
	cfg, err := agent.LoadConfig("")
	if err != nil {
		return agentConfigManifestEntry{}, false, err
	}
	def, ok := cfg.GetAgent(entry.Agent)
	if !ok {
		return agentConfigManifestEntry{}, false, fmt.Errorf("agent not configured: %s", entry.Agent)
	}
	switchSources, err := resolveAgentConfigSwitchSources(entry, def)
	if err != nil {
		return agentConfigManifestEntry{}, false, err
	}
	exists := false
	for _, source := range switchSources {
		sourcePath, err := expandUserPath(source.SourcePath)
		if err != nil {
			return agentConfigManifestEntry{}, false, err
		}
		if _, err := os.Stat(sourcePath); err == nil {
			exists = true
			break
		} else if err != nil && !os.IsNotExist(err) {
			return agentConfigManifestEntry{}, false, apperr.Wrap("stat", sourcePath, err)
		}
	}
	// Grok env-only profiles still rewrite ~/.grok/config.toml (api_key outranks
	// process env). Treat an existing live config as an overwrite target so the
	// UI confirmation path stays consistent with file-based profiles.
	if !exists && strings.EqualFold(strings.TrimSpace(entry.Agent), "grok") && len(entry.EnvKeys) > 0 {
		if configPath, err := expandUserPath("~/.grok/config.toml"); err == nil {
			if _, err := os.Stat(configPath); err == nil {
				exists = true
			} else if err != nil && !os.IsNotExist(err) {
				return agentConfigManifestEntry{}, false, apperr.Wrap("stat", configPath, err)
			}
		}
	}
	if exists && !req.ConfirmOverwrite {
		return entry, true, nil
	}
	configRoot, err := agentConfigRootDir()
	if err != nil {
		return agentConfigManifestEntry{}, false, err
	}
	for _, source := range switchSources {
		sourcePath, err := expandUserPath(source.SourcePath)
		if err != nil {
			return agentConfigManifestEntry{}, false, err
		}
		if err := copyFile(filepath.Join(configRoot, filepath.FromSlash(source.BackupPath)), sourcePath); err != nil {
			return agentConfigManifestEntry{}, false, err
		}
	}
	var env map[string]string
	if len(entry.EnvKeys) > 0 {
		envBackups, err := readAgentEnvBackups()
		if err != nil {
			return agentConfigManifestEntry{}, false, err
		}
		lines, ok := envBackups[entry.ID]
		if !ok {
			return agentConfigManifestEntry{}, false, errors.New("environment backup not found")
		}
		parsedEnv, _, err := envLinesToMap(lines)
		if err != nil {
			return agentConfigManifestEntry{}, false, err
		}
		env = parsedEnv
		if strings.EqualFold(strings.TrimSpace(entry.Agent), "grok") {
			env = normalizeGrokSwitchEnv(env)
			// Grok's config.toml api_key outranks process env. Env-only backups
			// must still rewrite the live config or /status keeps the old provider.
			if err := applyGrokConfigFromEnv(env); err != nil {
				return agentConfigManifestEntry{}, false, err
			}
		}
	}
	if err := updateAgentEnvConfig(entry.Agent, env); err != nil {
		return agentConfigManifestEntry{}, false, err
	}
	if app != nil && app.GetAgentPool() != nil {
		if err := app.GetAgentPool().SetAgentEnv(entry.Agent, env); err != nil {
			return agentConfigManifestEntry{}, false, err
		}
	}
	if app != nil && app.GetProber() != nil {
		if err := app.GetProber().SetAgentEnv(entry.Agent, env); err != nil {
			return agentConfigManifestEntry{}, false, err
		}
	}
	if app != nil && app.GetAgentPool() != nil {
		app.GetAgentPool().KillAgentProcess(entry.Agent, 0)
	}
	if app != nil {
		if err := app.ResetAgentSessionBindings(context.Background(), entry.Agent); err != nil {
			log.Printf("[agent-config] reset_session_bindings.error agent=%s err=%v", entry.Agent, err)
		}
	}
	if app != nil && app.GetPreferences() != nil {
		if err := app.GetPreferences().UpdateAgentLastConfigSelection(entry.Agent, preferences.LastConfigSelection{
			Type: "backup",
			ID:   entry.ID,
			Name: entry.Name,
		}); err != nil {
			return agentConfigManifestEntry{}, false, err
		}
	}
	if app != nil {
		app.BroadcastAgentStatusChanged(entry.Agent)
	}
	triggerAgentConfigSwitchProbe(app, entry.Agent)
	return entry, false, nil
}

func restartAgent(agentName string, app *AppContext) error {
	agentName = strings.TrimSpace(agentName)
	if agentName == "" {
		return errors.New("agent required")
	}
	if app == nil || app.GetAgentPool() == nil {
		return errors.New("agent pool not configured")
	}
	if _, ok := app.GetAgentPool().Config().GetAgent(agentName); !ok {
		return fmt.Errorf("agent not configured: %s", agentName)
	}
	app.GetAgentPool().KillAgentProcess(agentName, 0)
	triggerAgentConfigSwitchProbe(app, agentName)
	return nil
}

func triggerAgentConfigSwitchProbe(app *AppContext, agentName string) {
	if app == nil || app.GetProber() == nil {
		return
	}
	prober := app.GetProber()
	if err := prober.ClearProbeSession(agentName); err != nil {
		log.Printf("[agent-config] clear_probe_session.error agent=%s err=%v", agentName, err)
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
		defer cancel()
		status := prober.ProbeOne(ctx, agentName)
		if status.Error != "" {
			log.Printf("[agent-config] switch_probe.completed agent=%s available=%t err=%q", agentName, status.Available, status.Error)
			return
		}
		log.Printf("[agent-config] switch_probe.completed agent=%s available=%t", agentName, status.Available)
	}()
}

func normalizeAgentConfigRequest(agentName, backupName string) (string, string, string, error) {
	agentName = strings.TrimSpace(agentName)
	backupName = strings.TrimSpace(backupName)
	if agentName == "" {
		return "", "", "", errors.New("agent required")
	}
	if backupName == "" {
		return "", "", "", errors.New("backup name required")
	}
	if !agentConfigNamePattern.MatchString(backupName) || strings.Contains(backupName, "..") {
		return "", "", "", errors.New("backup name may only contain letters, numbers, dot, underscore, and hyphen")
	}
	return agentName, backupName, agentName + "-" + backupName, nil
}

func normalizeFileSources(input []string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	for _, item := range input {
		path := strings.TrimSpace(item)
		if path == "" {
			continue
		}
		path, err := expandUserPath(path)
		if err != nil {
			return nil, err
		}
		if seen[path] {
			continue
		}
		info, err := os.Stat(path)
		if err != nil {
			return nil, apperr.Wrap("stat", path, err)
		}
		if info.IsDir() {
			return nil, fmt.Errorf("config source is a directory: %s", path)
		}
		seen[path] = true
		out = append(out, path)
	}
	return out, nil
}

func existingDefaultFileSources(input []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, item := range input {
		path := strings.TrimSpace(item)
		if path == "" {
			continue
		}
		path, err := expandUserPath(path)
		if err != nil || path == "" || seen[path] {
			continue
		}
		info, err := os.Stat(path)
		if err != nil || info.IsDir() {
			continue
		}
		seen[path] = true
		out = append(out, path)
	}
	return out
}

func normalizeEnvLines(input []string) ([]string, []string, error) {
	var lines []string
	var keys []string
	seen := map[string]bool{}
	for _, raw := range input {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		rawKey, rawValue, ok := strings.Cut(line, "=")
		key := strings.TrimSpace(rawKey)
		if !ok || key == "" {
			return nil, nil, fmt.Errorf("invalid env line: %s", line)
		}
		value := strings.TrimSpace(rawValue)
		if value == "" {
			continue
		}
		lines = append(lines, key+"="+value)
		if !seen[key] {
			seen[key] = true
			keys = append(keys, key)
		}
	}
	return lines, keys, nil
}

func envLinesToMap(lines []string) (map[string]string, []string, error) {
	env := make(map[string]string, len(lines))
	var keys []string
	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			return nil, nil, fmt.Errorf("invalid env line: %s", line)
		}
		env[key] = value
		keys = append(keys, key)
	}
	return env, keys, nil
}

func expandUserPath(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", nil
	}
	if path != "~" && !strings.HasPrefix(path, "~/") && !strings.HasPrefix(path, `~\`) {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if path == "~" {
		return home, nil
	}
	return filepath.Join(home, strings.TrimLeft(path[1:], `/\`)), nil
}

func updateAgentConfigDefaults(agentName string, fileSources []string, envKeys []string) error {
	path, err := agent.ResolveConfigPath()
	if err != nil {
		return err
	}
	cfg, err := agent.LoadConfig("")
	if err != nil {
		return err
	}
	found := false
	for i := range cfg.Agents {
		if cfg.Agents[i].Name != agentName {
			continue
		}
		found = true
		cfg.Agents[i].ConfigBackup.FileSources = append([]string(nil), fileSources...)
		cfg.Agents[i].ConfigBackup.EnvKeys = append([]string(nil), envKeys...)
		break
	}
	if !found {
		return fmt.Errorf("agent not configured: %s", agentName)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return apperr.Wrap("mkdir", filepath.Dir(path), err)
	}
	payload, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	return apperr.Wrap("write", path, os.WriteFile(path, payload, 0o644))
}

func updateAgentEnvConfig(agentName string, env map[string]string) error {
	path, err := agent.ResolveConfigPath()
	if err != nil {
		return err
	}
	cfg, err := agent.LoadConfig("")
	if err != nil {
		return err
	}
	found := false
	for i := range cfg.Agents {
		if cfg.Agents[i].Name != agentName {
			continue
		}
		found = true
		cfg.Agents[i].Env = cloneStringMap(env)
		break
	}
	if !found {
		return fmt.Errorf("agent not configured: %s", agentName)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return apperr.Wrap("mkdir", filepath.Dir(path), err)
	}
	payload, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	return apperr.Wrap("write", path, os.WriteFile(path, payload, 0o644))
}

func cloneStringMap(input map[string]string) map[string]string {
	if len(input) == 0 {
		return nil
	}
	out := make(map[string]string, len(input))
	for key, value := range input {
		out[key] = value
	}
	return out
}

func readAgentConfigManifest() ([]agentConfigManifestEntry, error) {
	path, err := agentConfigManifestPath()
	if err != nil {
		return nil, err
	}
	payload, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []agentConfigManifestEntry{}, nil
		}
		return nil, apperr.Wrap("read", path, err)
	}
	var manifest []agentConfigManifestEntry
	if len(strings.TrimSpace(string(payload))) == 0 {
		return []agentConfigManifestEntry{}, nil
	}
	if err := json.Unmarshal(payload, &manifest); err != nil {
		return nil, err
	}
	return manifest, nil
}

func writeAgentConfigManifest(manifest []agentConfigManifestEntry) error {
	path, err := agentConfigManifestPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return apperr.Wrap("mkdir", filepath.Dir(path), err)
	}
	payload, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	return apperr.Wrap("write", path, os.WriteFile(path, payload, 0o644))
}

func readAgentEnvBackups() (map[string][]string, error) {
	path, err := agentEnvPath()
	if err != nil {
		return nil, err
	}
	payload, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string][]string{}, nil
		}
		return nil, apperr.Wrap("read", path, err)
	}
	if len(strings.TrimSpace(string(payload))) == 0 {
		return map[string][]string{}, nil
	}
	var out map[string][]string
	if err := json.Unmarshal(payload, &out); err != nil {
		return nil, err
	}
	if out == nil {
		out = map[string][]string{}
	}
	return out, nil
}

func writeAgentEnvBackups(env map[string][]string) error {
	path, err := agentEnvPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return apperr.Wrap("mkdir", filepath.Dir(path), err)
	}
	payload, err := json.MarshalIndent(env, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	return apperr.Wrap("write", path, os.WriteFile(path, payload, 0o644))
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return apperr.Wrap("open", src, err)
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return apperr.Wrap("mkdir", filepath.Dir(dst), err)
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return apperr.Wrap("write", dst, err)
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return apperr.Wrap("copy", dst, err)
	}
	return apperr.Wrap("write", dst, out.Close())
}

func agentConfigRootDir() (string, error) {
	configDir, err := configpkg.MindFSConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(configDir, "agents-config"), nil
}

func agentConfigManifestPath() (string, error) {
	root, err := agentConfigRootDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "manifest.json"), nil
}

func agentEnvPath() (string, error) {
	configDir, err := configpkg.MindFSConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(configDir, "agents-env.json"), nil
}
