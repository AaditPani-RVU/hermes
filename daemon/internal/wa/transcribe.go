package wa

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// ---- Voice-note transcription ----
//
// Runs whisper.cpp locally (installed by hermes-whisper-setup); audio never leaves the machine.
// The transcript is stored as the voice message's text, which WhatsApp never fills for voice notes,
// so search, previews and notifications pick it up for free. Progress lives in the message's
// extra JSON as "transcript": "pending" | "done" | "failed".

type transcribeJob struct{ chat, id string }

// whisperPaths returns the whisper-cli binary and model, or "" if transcription isn't set up.
func (c *Core) whisperPaths() (bin, model string) {
	dir := filepath.Join(c.Paths.Data, "whisper")
	bin, model = filepath.Join(dir, "whisper-cli"), filepath.Join(dir, "models", "default.bin")
	if _, err := os.Stat(bin); err != nil {
		return "", ""
	}
	if _, err := os.Stat(model); err != nil {
		return "", ""
	}
	return bin, model
}

// WhisperInstalled reports whether whisper.cpp and a model are in place.
func (c *Core) WhisperInstalled() (bool, string) {
	bin, model := c.whisperPaths()
	if bin == "" {
		return false, ""
	}
	target, _ := os.Readlink(model)
	return true, target
}

// TranscribeAvailable reports whether whisper is installed and the user hasn't turned it off.
func (c *Core) TranscribeAvailable(ctx context.Context) bool {
	bin, _ := c.whisperPaths()
	return bin != "" && c.Store.GetKV(ctx, "transcribe") != "off"
}

// QueueTranscription asks for a voice/audio message to be transcribed in the background.
func (c *Core) QueueTranscription(ctx context.Context, chat, id string) error {
	if bin, _ := c.whisperPaths(); bin == "" {
		return errors.New("transcription isn't set up; run hermes-whisper-setup")
	}
	m, err := c.Store.GetMessage(ctx, chat, id)
	if err != nil || m == nil {
		return errors.New("message not found")
	}
	if m.Type != "voice" && m.Type != "audio" {
		return errors.New("only voice notes and audio can be transcribed")
	}
	if m.Revoked || m.ViewOnce {
		return errors.New("this message can't be transcribed")
	}
	if err := c.setTranscriptState(ctx, m, "pending", m.Text); err != nil {
		return err
	}
	select {
	case c.transcribeQ <- transcribeJob{chat, id}:
		return nil
	default:
		_ = c.setTranscriptState(ctx, m, "failed", m.Text)
		return errors.New("transcription queue is full, try again shortly")
	}
}

func (c *Core) transcribeLoop(ctx context.Context) {
	// Requeue anything a restart interrupted.
	if rows, err := c.Store.DB.QueryContext(ctx, `SELECT chat, id FROM hermes_messages
		WHERE extra LIKE '%"transcript":"pending"%' ORDER BY ts DESC LIMIT 100`); err == nil {
		for rows.Next() {
			var j transcribeJob
			if rows.Scan(&j.chat, &j.id) == nil {
				select {
				case c.transcribeQ <- j:
				default:
				}
			}
		}
		rows.Close()
	}
	for {
		select {
		case <-ctx.Done():
			return
		case job := <-c.transcribeQ:
			if err := c.transcribe(ctx, job); err != nil {
				c.Log.Warnf("transcribe %s: %v", job.id, err)
				if m, _ := c.Store.GetMessage(ctx, job.chat, job.id); m != nil {
					_ = c.setTranscriptState(ctx, m, "failed", m.Text)
				}
			}
		}
	}
}

func (c *Core) transcribe(ctx context.Context, job transcribeJob) error {
	bin, model := c.whisperPaths()
	if bin == "" {
		return errors.New("whisper not installed")
	}
	path, err := c.DownloadMedia(ctx, job.chat, job.id)
	if err != nil {
		return err
	}
	wav := filepath.Join(c.Paths.TmpDir(), "whisper-"+safeName(job.id)+".wav")
	defer os.Remove(wav)

	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	conv := exec.CommandContext(ctx, "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", path,
		"-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav)
	if out, err := conv.CombinedOutput(); err != nil {
		return fmt.Errorf("ffmpeg: %v: %s", err, strings.TrimSpace(string(out)))
	}
	out, err := c.runWhisper(ctx, bin, model, wav)
	if err != nil {
		// GPU builds can fail when the driver is busy or asleep; retry on the CPU if there's a fallback.
		dir := filepath.Join(c.Paths.Data, "whisper")
		cpu, small := filepath.Join(dir, "whisper-cli-cpu"), filepath.Join(dir, "models", "fallback.bin")
		if _, e1 := os.Stat(cpu); e1 == nil {
			if _, e2 := os.Stat(small); e2 == nil {
				c.Log.Warnf("whisper failed (%v), retrying on CPU", err)
				out, err = c.runWhisper(ctx, cpu, small, wav)
			}
		}
	}
	if err != nil {
		return err
	}
	text := cleanTranscript(string(out))
	m, err := c.Store.GetMessage(ctx, job.chat, job.id)
	if err != nil || m == nil {
		return errors.New("message vanished")
	}
	if m.Revoked {
		return nil
	}
	return c.setTranscriptState(ctx, m, "done", text)
}

func (c *Core) runWhisper(ctx context.Context, bin, model, wav string) ([]byte, error) {
	threads := max(1, runtime.NumCPU()/2) // leave the desktop responsive
	cmd := exec.CommandContext(ctx, "nice", "-n", "10", bin, "-m", model, "-f", wav,
		"-l", "auto", "-t", fmt.Sprint(threads), "-nt", "-np")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("whisper: %v", err)
	}
	return out, nil
}

// Whisper marks non-speech as [BLANK_AUDIO], (music), *laughs* and the like.
var nonSpeech = regexp.MustCompile(`\[[^\]]*\]|\([^)]*\)|\*[^*]*\*`)

func cleanTranscript(s string) string {
	s = nonSpeech.ReplaceAllString(s, " ")
	return strings.Join(strings.Fields(s), " ")
}

func (c *Core) setTranscriptState(ctx context.Context, m *hs.Message, state, text string) error {
	extra := map[string]any{}
	if m.Extra != "" {
		_ = json.Unmarshal([]byte(m.Extra), &extra)
	}
	extra["transcript"] = state
	if err := c.Store.SetTranscript(ctx, m.Chat, m.ID, text, hs.MarshalExtra(extra)); err != nil {
		return err
	}
	c.emitMessage(ctx, m.Chat, m.ID)
	if state == "done" {
		c.emitChat(ctx, m.Chat) // preview changes from "Voice message" to the words
	}
	return nil
}

// autoTranscribe queues incoming voice notes when transcription is set up.
func (c *Core) autoTranscribe(ctx context.Context, m *hs.Message) {
	if m.Type != "voice" || m.FromMe || m.ViewOnce || !c.TranscribeAvailable(ctx) {
		return
	}
	if err := c.QueueTranscription(ctx, m.Chat, m.ID); err != nil {
		c.Log.Warnf("queue transcription: %v", err)
	}
}
