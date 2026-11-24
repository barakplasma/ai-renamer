package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"unicode/utf8"
)

func config(overrides []string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(home, "ai-renamer.json")
	if len(overrides) > 0 {
		lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return "", err
		}
		defer lock.Close()
		if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
			return "", err
		}
	}
	data := make(map[string]any)
	raw, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	if json.Unmarshal(raw, &data) != nil || data == nil {
		data = make(map[string]any)
	}
	if len(overrides) > 0 {
		for i := 0; i < len(overrides); i += 2 {
			data[overrides[i]] = overrides[i+1]
		}
		file, err := os.CreateTemp(home, ".ai-renamer-*")
		if err != nil {
			return "", err
		}
		defer os.Remove(file.Name())
		encoder := json.NewEncoder(file)
		encoder.SetIndent("", "  ")
		writeErr := encoder.Encode(data)
		closeErr := file.Close()
		if err := errors.Join(writeErr, closeErr); err != nil {
			return "", err
		}
		if err := os.Rename(file.Name(), path); err != nil {
			return "", err
		}
	}
	var fields []string
	for key, value := range data {
		text := fmt.Sprint(value)
		if !strings.ContainsRune(key, 0) && !strings.ContainsRune(text, 0) {
			fields = append(fields, key, text)
		}
	}
	return strings.Join(fields, "\x00"), nil
}

var scannedFiles sync.Map

func scan(path string, recursive bool) (string, error) {
	root, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	// Resolve ancestor components once and continue to reject a symlink at the leaf.
	parent, err := filepath.EvalSymlinks(filepath.Dir(root))
	if err != nil {
		return "", err
	}
	root = filepath.Join(parent, filepath.Base(root))
	info, err := os.Lstat(root)
	if err != nil {
		return "", err
	}
	if info.Mode().IsRegular() {
		if !utf8.ValidString(root) {
			return "", fmt.Errorf("input path is not valid UTF-8")
		}
		scannedFiles.Store(root, metadata(info))
		return strings.Join([]string{"file", root, filepath.Base(root), strings.TrimPrefix(filepath.Ext(root), ".")}, "\x00"), nil
	}
	if !info.IsDir() {
		return "", fmt.Errorf("input must be a regular file or directory")
	}
	visited := make(map[[2]uint64]bool)
	var records []string
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		shown, _ := filepath.Rel(root, path)
		if walkErr != nil {
			if path == root {
				return walkErr
			}
			records = append(records, "warn", "", walkErr.Error(), "")
			return nil
		}
		if !utf8.ValidString(path) {
			records = append(records, "warn", "", "Skipped a path with invalid UTF-8.", "")
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.IsDir() {
			if path != root && !recursive {
				return filepath.SkipDir
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			st := info.Sys().(*syscall.Stat_t)
			key := [2]uint64{uint64(st.Dev), uint64(st.Ino)}
			if visited[key] {
				return filepath.SkipDir
			}
			visited[key] = true
			records = append(records, "dir", path, shown, "")
		} else if entry.Type().IsRegular() {
			info, err := entry.Info()
			if err != nil {
				records = append(records, "warn", "", err.Error(), "")
				return nil
			}
			if !info.Mode().IsRegular() {
				return nil
			}
			scannedFiles.Store(path, metadata(info))
			records = append(records, "file", path, shown, strings.TrimPrefix(filepath.Ext(path), "."))
		}
		return nil
	})
	return strings.Join(records, "\x00"), err
}
