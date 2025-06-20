package api

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type FSEntry struct {
	Name    string    `json:"name"`
	Path    string    `json:"path"`
	IsDir   bool      `json:"is_dir"`
	Size    int64     `json:"size"`
	Mode    string    `json:"mode"`
	ModTime time.Time `json:"mod_time"`
}

type FileInfo struct {
	FSEntry
	MimeType   string `json:"mime_type"`
	Readable   bool   `json:"readable"`
	Executable bool   `json:"executable"`
}

func BrowseDirectory(path string) ([]FSEntry, error) {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}

	entries, err := os.ReadDir(absPath)
	if err != nil {
		return nil, err
	}

	var result []FSEntry
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}

		fsEntry := FSEntry{
			Name:    entry.Name(),
			Path:    filepath.Join(absPath, entry.Name()),
			IsDir:   entry.IsDir(),
			Size:    info.Size(),
			Mode:    info.Mode().String(),
			ModTime: info.ModTime(),
		}

		result = append(result, fsEntry)
	}

	return result, nil
}

// GetFileInfo returns detailed information about a file
func GetFileInfo(path string) (*FileInfo, error) {
	// Prevent path traversal attacks
	cleanPath := filepath.Clean(path)
	if strings.Contains(cleanPath, "..") {
		return nil, fmt.Errorf("invalid path: path traversal detected")
	}

	absPath, err := filepath.Abs(cleanPath)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve path: %w", err)
	}

	info, err := os.Stat(absPath)
	if err != nil {
		return nil, fmt.Errorf("failed to stat file: %w", err)
	}

	if info.IsDir() {
		return nil, fmt.Errorf("path is a directory, not a file")
	}

	// Detect MIME type
	mimeType := "application/octet-stream"
	file, err := os.Open(absPath)
	if err == nil {
		defer file.Close()

		// Read first 512 bytes for content detection
		buffer := make([]byte, 512)
		n, _ := file.Read(buffer)
		if n > 0 {
			mimeType = http.DetectContentType(buffer[:n])
		}
	}

	// Check permissions
	mode := info.Mode()
	readable := mode&0400 != 0
	executable := mode&0100 != 0

	return &FileInfo{
		FSEntry: FSEntry{
			Name:    info.Name(),
			Path:    absPath,
			IsDir:   false,
			Size:    info.Size(),
			Mode:    mode.String(),
			ModTime: info.ModTime(),
		},
		MimeType:   mimeType,
		Readable:   readable,
		Executable: executable,
	}, nil
}

// ReadFile opens a file for reading with security checks
func ReadFile(path string) (io.ReadCloser, *FileInfo, error) {
	fileInfo, err := GetFileInfo(path)
	if err != nil {
		return nil, nil, err
	}

	if !fileInfo.Readable {
		return nil, nil, fmt.Errorf("file is not readable")
	}

	file, err := os.Open(fileInfo.Path)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to open file: %w", err)
	}

	return file, fileInfo, nil
}
