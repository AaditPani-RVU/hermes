package wa

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"filippo.io/age"
)

// BackupDir is where backups go: kv backup_dir, else ~/Documents/Hermes backups.
func (c *Core) BackupDir(ctx context.Context) string {
	if d := c.Store.GetKV(ctx, "backup_dir"); d != "" {
		return expandHome(d)
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Documents", "Hermes backups")
}

type BackupResult struct {
	Path  string `json:"path"`
	Size  int64  `json:"size"`
	Files int    `json:"files"`
}

var backupMu sync.Mutex

// backupKeep is how many backups to keep in the backup folder; older hermes-*.tar.gz.age files are removed.
const backupKeep = 5

// Backup writes an age-encrypted (passphrase) tar.gz of the database and, optionally, downloaded media.
// The database holds the WhatsApp session keys, so the archive is only ever written encrypted.
func (c *Core) Backup(ctx context.Context, passphrase string, media bool) (*BackupResult, error) {
	if len(passphrase) < 8 {
		return nil, errors.New("use a passphrase of at least 8 characters")
	}
	if !backupMu.TryLock() {
		return nil, errors.New("a backup is already running")
	}
	defer backupMu.Unlock()
	c.Emit("backup.progress", map[string]any{"running": true})
	defer c.Emit("backup.progress", map[string]any{"running": false})

	dir := c.BackupDir(ctx)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	snap := filepath.Join(c.Paths.TmpDir(), "backup.db")
	if err := c.Store.Snapshot(ctx, snap); err != nil {
		return nil, fmt.Errorf("snapshot database: %w", err)
	}
	defer os.Remove(snap)

	rcpt, err := age.NewScryptRecipient(passphrase)
	if err != nil {
		return nil, err
	}
	out := filepath.Join(dir, "hermes-"+time.Now().Format("2006-01-02-1504")+".tar.gz.age")
	tmp := out + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp)
	res := &BackupResult{Path: out}
	err = func() error {
		enc, err := age.Encrypt(f, rcpt)
		if err != nil {
			return err
		}
		gz := gzip.NewWriter(enc)
		tw := tar.NewWriter(gz)
		if err := addFile(tw, snap, "hermes.db"); err != nil {
			return err
		}
		res.Files++
		for _, extra := range []string{"notify-icon.png", "notify-icon.svg"} {
			if p := filepath.Join(c.Paths.Data, extra); fileExists(p) {
				if err := addFile(tw, p, extra); err == nil {
					res.Files++
				}
			}
		}
		if media {
			root := c.Paths.MediaDir()
			err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
				if err != nil || d.IsDir() {
					return err
				}
				if ctx.Err() != nil {
					return ctx.Err()
				}
				rel, _ := filepath.Rel(c.Paths.Data, p)
				if err := addFile(tw, p, filepath.ToSlash(rel)); err != nil {
					return err
				}
				res.Files++
				return nil
			})
			if err != nil {
				return err
			}
		}
		if err := tw.Close(); err != nil {
			return err
		}
		if err := gz.Close(); err != nil {
			return err
		}
		return enc.Close()
	}()
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return nil, err
	}
	if err := os.Rename(tmp, out); err != nil {
		return nil, err
	}
	if st, err := os.Stat(out); err == nil {
		res.Size = st.Size()
	}
	_ = c.Store.SetKV(ctx, "backup_last", fmt.Sprint(time.Now().Unix()))
	pruneBackups(dir, backupKeep)
	return res, nil
}

func addFile(tw *tar.Writer, path, name string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	hdr := &tar.Header{Name: name, Mode: 0o600, Size: st.Size(), ModTime: st.ModTime(), Typeflag: tar.TypeReg}
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	_, err = io.CopyN(tw, f, st.Size())
	return err
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func pruneBackups(dir string, keep int) {
	matches, _ := filepath.Glob(filepath.Join(dir, "hermes-*.tar.gz.age"))
	sort.Strings(matches) // names sort by date
	for len(matches) > keep {
		_ = os.Remove(matches[0])
		matches = matches[1:]
	}
}

type BackupInfo struct {
	Dir  string `json:"dir"`
	Last int64  `json:"last"`
	List []struct {
		Path string `json:"path"`
		Size int64  `json:"size"`
	} `json:"list"`
}

func (c *Core) BackupInfo(ctx context.Context) *BackupInfo {
	info := &BackupInfo{Dir: c.BackupDir(ctx)}
	fmt.Sscan(c.Store.GetKV(ctx, "backup_last"), &info.Last)
	matches, _ := filepath.Glob(filepath.Join(info.Dir, "hermes-*.tar.gz.age"))
	sort.Sort(sort.Reverse(sort.StringSlice(matches)))
	for _, m := range matches {
		st, err := os.Stat(m)
		if err != nil {
			continue
		}
		info.List = append(info.List, struct {
			Path string `json:"path"`
			Size int64  `json:"size"`
		}{m, st.Size()})
	}
	return info
}
