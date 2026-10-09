// Package backup reads Hermes' encrypted backups. It has no WhatsApp dependencies,
// so the CLI can extract a backup without hermesd running.
package backup

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"filippo.io/age"
)

// Extract decrypts a backup into dir (which must be empty or missing). It never touches
// the live data directory; restoring is a manual copy with hermesd stopped.
func Extract(path, passphrase, dir string) ([]string, error) {
	if ents, err := os.ReadDir(dir); err == nil && len(ents) > 0 {
		return nil, fmt.Errorf("%s is not empty", dir)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	id, err := age.NewScryptIdentity(passphrase)
	if err != nil {
		return nil, err
	}
	dec, err := age.Decrypt(f, id)
	if err != nil {
		return nil, fmt.Errorf("decrypt (wrong passphrase?): %w", err)
	}
	gz, err := gzip.NewReader(dec)
	if err != nil {
		return nil, err
	}
	tr := tar.NewReader(gz)
	var names []string
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		} else if err != nil {
			return names, err
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		clean := filepath.Clean(filepath.FromSlash(hdr.Name))
		if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return names, fmt.Errorf("unsafe path in archive: %s", hdr.Name)
		}
		dst := filepath.Join(dir, clean)
		if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
			return names, err
		}
		out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			return names, err
		}
		_, err = io.Copy(out, tr)
		out.Close()
		if err != nil {
			return names, err
		}
		names = append(names, clean)
	}
	return names, nil
}
