package api

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"mindfs/server/internal/agent"
	configpkg "mindfs/server/internal/config"
)

// configBackupMaxFileSize caps a single file copied into the archive so a
// corrupted or misplaced huge file cannot make the download unbounded.
const configBackupMaxFileSize = 64 << 20

// handleConfigBackupDownload streams a tar.gz archive of every file MindFS
// needs to restore its channel configuration on a fresh machine: the config
// profiles directory (agents-config/), profile env values (agents-env.json),
// API providers (api-providers.json), and the user agents.json definitions.
func (h *HTTPHandler) handleConfigBackupDownload(w http.ResponseWriter, r *http.Request) {
	configDir, err := configpkg.MindFSConfigDir()
	if err != nil {
		respondError(w, http.StatusInternalServerError, err)
		return
	}
	agentsConfigPath, err := agent.ResolveConfigPath()
	if err != nil {
		respondError(w, http.StatusInternalServerError, err)
		return
	}

	// Archive entries use fixed logical prefixes rather than absolute host
	// paths so a backup restores cleanly regardless of the original layout.
	type backupEntry struct {
		fsPath      string
		archivePath string
		required    bool
	}
	entries := []backupEntry{
		{fsPath: filepath.Join(configDir, "agents-config"), archivePath: "config/agents-config"},
		{fsPath: filepath.Join(configDir, "agents-env.json"), archivePath: "config/agents-env.json"},
		{fsPath: filepath.Join(configDir, "api-providers.json"), archivePath: "config/api-providers.json"},
		{fsPath: agentsConfigPath, archivePath: "config/agents.json"},
	}

	filename := fmt.Sprintf("mindfs-config-backup-%s.tar.gz", time.Now().UTC().Format("20060102T150405Z"))
	w.Header().Set("Content-Type", "application/gzip")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", filename))

	gzw := gzip.NewWriter(w)
	tw := tar.NewWriter(gzw)
	defer func() {
		_ = tw.Close()
		_ = gzw.Close()
	}()

	for _, entry := range entries {
		info, err := os.Stat(entry.fsPath)
		if err != nil {
			if os.IsNotExist(err) && !entry.required {
				continue
			}
			// Headers are already sent; abort mid-stream so the client sees a
			// truncated archive instead of a silently incomplete backup.
			return
		}
		if info.IsDir() {
			if err := addDirToTar(tw, entry.fsPath, entry.archivePath); err != nil {
				return
			}
			continue
		}
		if err := addFileToTar(tw, entry.fsPath, entry.archivePath, info); err != nil {
			return
		}
	}
}

func addDirToTar(tw *tar.Writer, dir, archivePrefix string) error {
	return filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		archivePath := archivePrefix
		if rel != "." {
			archivePath = archivePrefix + "/" + filepath.ToSlash(rel)
		}
		if info.IsDir() {
			header := &tar.Header{
				Name:     archivePath + "/",
				Mode:     0o700,
				Typeflag: tar.TypeDir,
				ModTime:  info.ModTime(),
			}
			return tw.WriteHeader(header)
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		return addFileToTar(tw, path, archivePath, info)
	})
}

func addFileToTar(tw *tar.Writer, path, archivePath string, info os.FileInfo) error {
	if info.Size() > configBackupMaxFileSize {
		return fmt.Errorf("file too large for backup: %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() {
		_ = file.Close()
	}()
	header := &tar.Header{
		Name:    strings.TrimPrefix(archivePath, "/"),
		Mode:    0o600,
		Size:    info.Size(),
		ModTime: info.ModTime(),
	}
	if err := tw.WriteHeader(header); err != nil {
		return err
	}
	_, err = io.CopyN(tw, file, info.Size())
	return err
}
