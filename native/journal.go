package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

const journalVersion = 1

var runID = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$`)
var activeRun struct {
	sync.Mutex
	file   *os.File
	broken error
}

type inode struct{ Device, Number uint64 }

func identity(info fs.FileInfo) inode {
	stat := info.Sys().(*syscall.Stat_t)
	return inode{uint64(stat.Dev), uint64(stat.Ino)}
}

type fingerprint struct {
	Inode    inode
	Bytes    int64
	Modified int64
	Digest   [32]byte
}

type move struct {
	Directory string
	Parent    inode
	Original  string
	Renamed   string
	File      fingerprint
}

func journalDir() (string, error) {
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		base = filepath.Join(home, ".local", "state")
	}
	if !filepath.IsAbs(base) {
		return "", errors.New("XDG_STATE_HOME must be absolute")
	}
	return filepath.Join(base, "ai-renamer"), nil
}

func syncDir(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func ensureStateDir(path string) error {
	var created []string
	for current := path; ; current = filepath.Dir(current) {
		info, err := os.Stat(current)
		if err == nil {
			if !info.IsDir() {
				return fmt.Errorf("%s is not a directory", current)
			}
			break
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		created = append(created, current)
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	for i := len(created) - 1; i >= 0; i-- {
		if err := syncDir(filepath.Dir(created[i])); err != nil {
			return err
		}
	}
	return nil
}

func lockMutations() (*os.File, error) {
	dir, err := journalDir()
	if err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "mutations.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		lock.Close()
		return nil, err
	}
	return lock, nil
}

func beginRun() (string, error) {
	activeRun.Lock()
	defer activeRun.Unlock()
	if activeRun.file != nil {
		return "", errors.New("a rename run is already open")
	}
	path, err := journalDir()
	if err != nil {
		return "", err
	}
	if err := ensureStateDir(path); err != nil {
		return "", err
	}
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	id := time.Now().UTC().Format("20060102T150405Z") + "-" + hex.EncodeToString(random[:])
	file, err := os.OpenFile(filepath.Join(path, id+".jsonl"), os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	if err != nil {
		return "", err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		file.Close()
		return "", err
	}
	err = json.NewEncoder(file).Encode(struct{ Version int }{journalVersion})
	if err == nil {
		err = file.Sync()
	}
	if err == nil {
		err = syncDir(path)
	}
	if err != nil {
		file.Close()
		return "", err
	}
	activeRun.file = file
	return id, nil
}

func openDirectory(path string) (*os.File, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}

// A rooted handle prevents a later path change from redirecting file reads.
// The directory descriptor also anchors the exclusive rename itself.
func openTargetDir(path string) (*os.File, *os.Root, inode, error) {
	path = filepath.Clean(path)
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return nil, nil, inode{}, err
	}
	if resolved != path {
		return nil, nil, inode{}, errors.New("directory contains a symlink")
	}
	dir, err := openDirectory(path)
	if err != nil {
		return nil, nil, inode{}, err
	}
	info, err := dir.Stat()
	if err != nil {
		dir.Close()
		return nil, nil, inode{}, err
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		dir.Close()
		return nil, nil, inode{}, err
	}
	rootInfo, err := root.Stat(".")
	if err != nil || !os.SameFile(info, rootInfo) {
		root.Close()
		dir.Close()
		return nil, nil, inode{}, errors.New("directory changed while opening it")
	}
	return dir, root, identity(info), nil
}

func metadata(info fs.FileInfo) fingerprint {
	return fingerprint{Inode: identity(info), Bytes: info.Size(), Modified: info.ModTime().UnixNano()}
}

func fingerprintAt(root *os.Root, name string) (fingerprint, error) {
	pathInfo, err := root.Lstat(name)
	if err != nil {
		return fingerprint{}, err
	}
	if !pathInfo.Mode().IsRegular() {
		return fingerprint{}, errors.New("path is not a regular file")
	}
	file, err := root.Open(name)
	if err != nil {
		return fingerprint{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return fingerprint{}, err
	}
	baseline := metadata(pathInfo)
	if !info.Mode().IsRegular() || metadata(info) != baseline {
		return fingerprint{}, errors.New("file changed while opening it")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return fingerprint{}, err
	}
	info, err = file.Stat()
	if err != nil {
		return fingerprint{}, err
	}
	if metadata(info) != baseline {
		return fingerprint{}, errors.New("file changed while hashing it")
	}
	copy(baseline.Digest[:], hash.Sum(nil))
	return baseline, nil
}

func stillMatches(root *os.Root, name string, want fingerprint) bool {
	info, err := root.Lstat(name)
	want.Digest = [32]byte{}
	return err == nil && info.Mode().IsRegular() && metadata(info) == want
}

func cleanComponent(name string) bool {
	return name != "" && name != "." && name != ".." && filepath.Base(name) == name &&
		strings.IndexFunc(name, func(r rune) bool {
			return r < 32 || strings.ContainsRune(`/\:*?"<>|`, r)
		}) == -1
}

func trimBytes(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	for limit > 0 && !utf8.RuneStart(s[limit]) {
		limit--
	}
	return s[:limit]
}

func renameFile(path, stem, shown string) (string, error) {
	if !cleanComponent(stem) {
		return "", errors.New("model did not return a safe filename")
	}
	parent, original := filepath.Dir(path), filepath.Base(path)
	dir, root, id, err := openTargetDir(parent)
	if err != nil {
		return "", err
	}
	defer dir.Close()
	defer root.Close()
	stamp, err := fingerprintAt(root, original)
	if err != nil {
		return "", err
	}
	initial, found := scannedFiles.Load(path)
	current := stamp
	current.Digest = [32]byte{}
	if !found || initial.(fingerprint) != current {
		return "", errors.New("source changed since directory scan")
	}
	ext := strings.ToLower(filepath.Ext(original))
	activeRun.Lock()
	defer activeRun.Unlock()
	if activeRun.file == nil {
		return "", errors.New("no recovery journal is open")
	}
	if activeRun.broken != nil {
		return "", activeRun.broken
	}
	lock, err := lockMutations()
	if err != nil {
		return "", err
	}
	defer lock.Close()
	for index := range 100000 {
		suffix := ext
		if index > 0 {
			suffix = fmt.Sprint(index) + suffix
		}
		if len(suffix) >= 255 {
			return "", errors.New("filename extension is too long")
		}
		trimmed := strings.TrimRight(trimBytes(stem, 255-len(suffix)), " .")
		if trimmed == "" {
			return "", errors.New("filename has no usable stem")
		}
		name := trimmed + suffix
		if name == original {
			return shown, nil
		}
		if !cleanComponent(name) {
			return "", errors.New("destination is not a safe filename")
		}
		if _, err := root.Lstat(name); err == nil {
			continue
		} else if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		if !stillMatches(root, original, stamp) {
			return "", errors.New("source changed before rename")
		}
		record := move{parent, id, original, name, stamp}
		if err := json.NewEncoder(activeRun.file).Encode(record); err != nil {
			activeRun.broken = fmt.Errorf("write recovery journal: %w", err)
			return "", activeRun.broken
		}
		if err := activeRun.file.Sync(); err != nil {
			activeRun.broken = fmt.Errorf("sync recovery journal: %w", err)
			return "", activeRun.broken
		}
		if !stillMatches(root, original, stamp) {
			return "", errors.New("source changed while writing recovery journal")
		}
		if err := moveExclusive(dir.Fd(), original, name); err != nil {
			return "", err
		}
		if err := dir.Sync(); err != nil {
			return "", fmt.Errorf("rename journaled; directory sync failed: %w", err)
		}
		return filepath.Join(filepath.Dir(shown), name), nil
	}
	return "", errors.New("no unused filename found")
}

func readJournal(file *os.File) ([]move, error) {
	raw, err := io.ReadAll(file)
	if err != nil {
		return nil, err
	}
	// An incomplete tail can only be an intent whose write did not complete.
	last := bytes.LastIndexByte(raw, '\n')
	if last < 0 {
		return nil, errors.New("recovery journal is incomplete")
	}
	lines := bytes.Split(raw[:last], []byte{'\n'})
	var header struct{ Version int }
	if err := json.Unmarshal(lines[0], &header); err != nil || header.Version != journalVersion {
		return nil, errors.New("unknown recovery journal format")
	}
	moves := make([]move, 0, len(lines)-1)
	for _, line := range lines[1:] {
		var record move
		err := json.Unmarshal(line, &record)
		if err != nil || !filepath.IsAbs(record.Directory) || filepath.Base(record.Original) != record.Original ||
			record.Original == "." || record.Original == ".." || record.Original == "" ||
			strings.ContainsRune(record.Original, 0) || !cleanComponent(record.Renamed) ||
			record.Original == record.Renamed || record.File.Digest == [32]byte{} {
			return nil, errors.New("invalid recovery journal record")
		}
		moves = append(moves, record)
	}
	return moves, nil
}

const missing = 0
const matching = 1
const different = 2

func pathState(root *os.Root, name string, want fingerprint) int {
	info, err := root.Lstat(name)
	if errors.Is(err, fs.ErrNotExist) {
		return missing
	}
	if err != nil || !info.Mode().IsRegular() || identity(info) != want.Inode {
		return different
	}
	current, err := fingerprintAt(root, name)
	if err == nil && current == want {
		return matching
	}
	return different
}

func undo(record move, policy string) (bool, error) {
	dir, root, id, err := openTargetDir(record.Directory)
	if err != nil {
		return false, err
	}
	defer dir.Close()
	defer root.Close()
	if id != record.Parent {
		return false, errors.New("original directory was replaced")
	}
	original := pathState(root, record.Original, record.File)
	renamed := pathState(root, record.Renamed, record.File)
	switch policy[3*original+renamed] {
	case 's':
		return false, nil
	case 'r':
		// Enforce the policy at the actual filesystem boundary as well.
		if original != missing || renamed != matching || !stillMatches(root, record.Renamed, record.File) {
			return false, errors.New("cannot safely restore this file")
		}
		if err := moveExclusive(dir.Fd(), record.Renamed, record.Original); err != nil {
			return false, err
		}
		return true, dir.Sync()
	default:
		return false, errors.New("original name is occupied or the renamed file was changed or removed")
	}
}

func rollback(id, policy string) (string, error) {
	if !runID.MatchString(id) || len(policy) != 9 {
		return "", errors.New("invalid rollback run ID or policy")
	}
	path, err := journalDir()
	if err != nil {
		return "", err
	}
	fd, err := syscall.Open(filepath.Join(path, id+".jsonl"), syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	file := os.NewFile(uintptr(fd), id)
	defer file.Close()
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return "", fmt.Errorf("run is still active or already being rolled back: %w", err)
	}
	records, err := readJournal(file)
	if err != nil {
		return "", err
	}
	lock, err := lockMutations()
	if err != nil {
		return "", err
	}
	defer lock.Close()
	var problems []error
	restored := 0
	for i := len(records) - 1; i >= 0; i-- {
		record := records[i]
		applied, err := undo(record, policy)
		if applied {
			restored++
		}
		if err != nil {
			problems = append(problems, fmt.Errorf("%s: %w", filepath.Join(record.Directory, record.Original), err))
		}
	}
	summary := fmt.Sprintf("Rollback %s restored %d file(s).", id, restored)
	if len(problems) != 0 {
		return "", fmt.Errorf("%s\n%w", summary, errors.Join(problems...))
	}
	return summary, nil
}

func listRuns() (string, error) {
	path, err := journalDir()
	if err != nil {
		return "", err
	}
	entries, err := os.ReadDir(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "No rename runs.", nil
	}
	if err != nil {
		return "", err
	}
	var ids []string
	for i := len(entries) - 1; i >= 0; i-- {
		entry := entries[i]
		id := strings.TrimSuffix(entry.Name(), ".jsonl")
		if entry.Type().IsRegular() && strings.HasSuffix(entry.Name(), ".jsonl") && runID.MatchString(id) {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return "No rename runs.", nil
	}
	return strings.Join(ids, "\n"), nil
}
