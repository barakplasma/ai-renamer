package main

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testPolicy = "crcscsccc"

func plannedMove(t *testing.T, original, renamed string) move {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, original), []byte("user content"), 0600); err != nil {
		t.Fatal(err)
	}
	fd, root, id, err := openTargetDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer fd.Close()
	defer root.Close()
	stamp, err := fingerprintAt(root, original)
	if err != nil {
		t.Fatal(err)
	}
	return move{dir, id, original, renamed, stamp}
}

func TestRollbackSkipsIntentInterruptedBeforeRename(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	record := plannedMove(t, "before.txt", "after.txt")
	id := "20261124T000000Z-0000000000000000"
	dir, err := journalDir()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	journal, err := os.Create(filepath.Join(dir, id+".jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	encoder := json.NewEncoder(journal)
	if err := encoder.Encode(map[string]int{"Version": journalVersion}); err != nil {
		t.Fatal(err)
	}
	if err := encoder.Encode(record); err != nil {
		t.Fatal(err)
	}
	if _, err := journal.WriteString(`{"Directory":`); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}

	summary, err := rollback(id, testPolicy)
	if err != nil || !strings.Contains(summary, "restored 0 file(s)") {
		t.Fatalf("rollback = %q, %v", summary, err)
	}
	source := filepath.Join(record.Directory, record.Original)
	body, err := os.ReadFile(source)
	if err != nil || string(body) != "user content" {
		t.Fatalf("original is %q, %v", body, err)
	}
	_, err = os.Lstat(filepath.Join(record.Directory, record.Renamed))
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("unexpected destination: %v", err)
	}
}
