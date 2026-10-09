package wa

import (
	"bufio"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// ---- Image OCR ----
//
// Text in downloaded images (screenshots, receipts, notices) is read locally with RapidOCR
// (installed by hermes-ocr-setup) and indexed for search in hermes_ocr. Images never leave the machine.
// A single Python helper stays alive while there's work and exits after a few idle minutes.

//go:embed assets/ocr.py
var ocrScript []byte

type ocrJob struct{ chat, id string }

const ocrIdle = 3 * time.Minute

type ocrProc struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Reader
}

type ocrState struct {
	mu   sync.Mutex
	proc *ocrProc
}

func (c *Core) ocrPython() string {
	dir := filepath.Join(c.Paths.Data, "ocr")
	py := filepath.Join(dir, "venv", "bin", "python")
	// .ready is written by hermes-ocr-setup once packages and models are in place.
	for _, p := range []string{py, filepath.Join(dir, ".ready")} {
		if _, err := os.Stat(p); err != nil {
			return ""
		}
	}
	return py
}

// OCRInstalled reports whether hermes-ocr-setup has run.
func (c *Core) OCRInstalled() bool { return c.ocrPython() != "" }

// OCRAvailable reports whether OCR is installed and not turned off.
func (c *Core) OCRAvailable(ctx context.Context) bool {
	return c.OCRInstalled() && c.Store.GetKV(ctx, "ocr") != "off"
}

// queueOCR schedules an image for OCR unless it has been scanned already. Never blocks.
func (c *Core) queueOCR(ctx context.Context, chat, id string) {
	if !c.OCRAvailable(ctx) {
		return
	}
	if _, done := c.Store.OCR(ctx, chat, id); done {
		return
	}
	select {
	case c.ocrQ <- ocrJob{chat, id}:
	default:
	}
}

// ImageText returns the text found in an image, scanning it now if needed.
func (c *Core) ImageText(ctx context.Context, chat, id string) (string, error) {
	if text, done := c.Store.OCR(ctx, chat, id); done {
		return text, nil
	}
	if !c.OCRInstalled() {
		return "", errors.New("OCR isn't set up; run hermes-ocr-setup")
	}
	return c.ocrOne(ctx, ocrJob{chat, id})
}

func (c *Core) ocrLoop(ctx context.Context) {
	backfill := time.NewTimer(45 * time.Second) // after startup sync settles
	idle := time.NewTimer(ocrIdle)
	defer c.ocrStop()
	for {
		select {
		case <-ctx.Done():
			return
		case job := <-c.ocrQ:
			if _, err := c.ocrOne(ctx, job); err != nil {
				c.Log.Warnf("ocr %s: %v", job.id, err)
			}
			idle.Reset(ocrIdle)
		case <-idle.C:
			c.ocrStop()
		case <-backfill.C:
			// Older images, a batch at a time so a big backlog never hogs the CPU for long.
			backfill.Reset(10 * time.Minute)
			if !c.OCRAvailable(ctx) {
				continue
			}
			todo, _ := c.Store.UnscannedImages(ctx, 40)
			for _, t := range todo {
				select {
				case c.ocrQ <- ocrJob{t[0], t[1]}:
				default:
				}
			}
		}
	}
}

// ocrOne scans one image and stores the result.
func (c *Core) ocrOne(ctx context.Context, job ocrJob) (string, error) {
	m, err := c.Store.GetMessage(ctx, job.chat, job.id)
	if err != nil || m == nil {
		return "", errors.New("message not found")
	}
	if m.Type != "image" || m.Revoked || m.ViewOnce {
		return "", errors.New("not an image")
	}
	path := m.MediaPath
	if _, err := os.Stat(path); path == "" || err != nil {
		if path, err = c.DownloadMedia(ctx, job.chat, job.id); err != nil {
			return "", err
		}
	}
	text, err := c.ocrRun(ctx, path)
	if err != nil {
		return "", err
	}
	if err := c.Store.SetOCR(ctx, job.chat, job.id, text); err != nil {
		return "", err
	}
	if text != "" {
		c.Emit("ocr", map[string]any{"chat": job.chat, "id": job.id})
	}
	return text, nil
}

func (c *Core) ocrRun(ctx context.Context, path string) (string, error) {
	c.ocr.mu.Lock()
	defer c.ocr.mu.Unlock()
	if c.ocr.proc == nil {
		p, err := c.ocrStart()
		if err != nil {
			return "", err
		}
		c.ocr.proc = p
	}
	p := c.ocr.proc
	if _, err := fmt.Fprintln(p.in, path); err != nil {
		c.ocrStopLocked()
		return "", err
	}
	type reply struct {
		Text  string `json:"text"`
		Error string `json:"error"`
	}
	done := make(chan reply, 1)
	go func() {
		line, err := p.out.ReadBytes('\n')
		var r reply
		if err != nil {
			r.Error = "ocr helper exited"
		} else if json.Unmarshal(line, &r) != nil {
			r.Error = "bad reply from ocr helper"
		}
		done <- r
	}()
	select {
	case r := <-done:
		if r.Error != "" {
			if r.Error == "ocr helper exited" {
				c.ocrStopLocked()
			}
			return "", errors.New(r.Error)
		}
		return r.Text, nil
	case <-time.After(2 * time.Minute):
		c.ocrStopLocked()
		return "", errors.New("ocr timed out")
	case <-ctx.Done():
		c.ocrStopLocked()
		return "", ctx.Err()
	}
}

func (c *Core) ocrStart() (*ocrProc, error) {
	py := c.ocrPython()
	if py == "" {
		return nil, errors.New("OCR isn't set up; run hermes-ocr-setup")
	}
	script := filepath.Join(c.Paths.Data, "ocr", "hermes_ocr.py")
	if err := os.WriteFile(script, ocrScript, 0o600); err != nil {
		return nil, err
	}
	// Few threads and low priority: OCR is background work and shouldn't make the desktop stutter.
	cmd := exec.Command("nice", "-n", "10", py, "-I", script)
	cmd.Env = append(os.Environ(), "OMP_NUM_THREADS=2")
	cmd.Dir = filepath.Join(c.Paths.Data, "ocr")
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &ocrProc{cmd: cmd, in: in, out: bufio.NewReader(out)}
	ready := make(chan error, 1)
	go func() {
		_, err := p.out.ReadBytes('\n') // {"ready": true} once the models are loaded
		ready <- err
	}()
	select {
	case err := <-ready:
		if err != nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			return nil, errors.New("ocr helper failed to start; re-run hermes-ocr-setup")
		}
	case <-time.After(90 * time.Second):
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, errors.New("ocr helper took too long to start")
	}
	return p, nil
}

func (c *Core) ocrStop() {
	c.ocr.mu.Lock()
	defer c.ocr.mu.Unlock()
	c.ocrStopLocked()
}

func (c *Core) ocrStopLocked() {
	if p := c.ocr.proc; p != nil {
		_ = p.in.Close()
		go func() {
			t := time.AfterFunc(5*time.Second, func() { _ = p.cmd.Process.Kill() })
			_ = p.cmd.Wait()
			t.Stop()
		}()
		c.ocr.proc = nil
	}
}
