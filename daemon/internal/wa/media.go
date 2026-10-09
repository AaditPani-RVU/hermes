package wa

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"mime"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

var extByMime = map[string]string{
	"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif",
	"video/mp4": ".mp4", "video/3gpp": ".3gp", "video/quicktime": ".mov",
	"audio/ogg": ".ogg", "audio/mpeg": ".mp3", "audio/mp4": ".m4a", "audio/aac": ".aac", "audio/amr": ".amr",
	"application/pdf": ".pdf",
}

func extFor(mimeType string) string {
	base := strings.TrimSpace(strings.SplitN(mimeType, ";", 2)[0])
	if e, ok := extByMime[base]; ok {
		return e
	}
	if exts, _ := mime.ExtensionsByType(base); len(exts) > 0 {
		return exts[0]
	}
	return ".bin"
}

// DownloadMedia fetches, decrypts, and caches a message's media, returning the local path.
func (c *Core) DownloadMedia(ctx context.Context, chat, id string) (string, error) {
	m, err := c.Store.GetMessage(ctx, chat, id)
	if err != nil {
		return "", err
	} else if m == nil {
		return "", errors.New("message not found")
	}
	if m.MediaPath != "" {
		if _, err := os.Stat(m.MediaPath); err == nil {
			return m.MediaPath, nil
		}
	}
	if len(m.Raw) == 0 {
		return "", errors.New("message has no media")
	}
	if err := c.loggedIn(); err != nil {
		return "", err
	}
	var msg waE2E.Message
	if err := proto.Unmarshal(m.Raw, &msg); err != nil {
		return "", err
	}
	data, err := c.cli.DownloadAny(ctx, &msg)
	if isExpiredMedia(err) {
		data, err = c.retryMedia(ctx, m, &msg)
	}
	if err != nil {
		return "", fmt.Errorf("download: %w", err)
	}
	dir := filepath.Join(c.Paths.MediaDir(), safeName(chat))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	name := safeName(id) + extFor(m.MediaMime)
	if m.FileName != "" {
		name = safeName(id) + "-" + safeName(filepath.Base(m.FileName))
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	if strings.HasPrefix(m.MediaMime, "image/webp") && !qtHasWebP() {
		if conv := webpFallback(ctx, path); conv != "" {
			path = conv
		}
	}
	_ = c.Store.SetMediaPath(ctx, chat, id, path)
	c.Emit("media", map[string]any{"chat": chat, "id": id, "path": path})
	if m.Type == "image" && !m.ViewOnce {
		c.queueOCR(ctx, chat, id)
	}
	return path, nil
}

func qtHasWebP() bool {
	matches, _ := filepath.Glob("/usr/lib/*/qt6/plugins/imageformats/libqwebp.so")
	return len(matches) > 0
}

// webpFallback converts a (possibly animated) WebP sticker to GIF/PNG with Pillow,
// because Qt can't show WebP without qt6-image-formats-plugins.
func webpFallback(ctx context.Context, path string) string {
	const script = `import sys
from PIL import Image
src = sys.argv[1]
im = Image.open(src)
if getattr(im, "is_animated", False):
    out = src.rsplit(".", 1)[0] + ".gif"
    im.save(out, save_all=True, loop=0, disposal=2, transparency=0, optimize=False)
else:
    out = src.rsplit(".", 1)[0] + ".png"
    im.save(out)
print(out)`
	out, err := exec.CommandContext(ctx, "python3", "-I", "-c", script, path).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

type probeResult struct {
	W, H int
	Secs float64
}

func probe(ctx context.Context, path string) probeResult {
	out, err := exec.CommandContext(ctx, "ffprobe", "-v", "error", "-show_entries",
		"stream=width,height:format=duration", "-of", "json", path).Output()
	var r probeResult
	if err != nil {
		return r
	}
	var parsed struct {
		Streams []struct {
			Width  int `json:"width"`
			Height int `json:"height"`
		} `json:"streams"`
		Format struct {
			Duration string `json:"duration"`
		} `json:"format"`
	}
	if json.Unmarshal(out, &parsed) == nil {
		for _, s := range parsed.Streams {
			if s.Width > 0 {
				r.W, r.H = s.Width, s.Height
				break
			}
		}
		r.Secs, _ = strconv.ParseFloat(parsed.Format.Duration, 64)
	}
	return r
}

func ffmpeg(ctx context.Context, args ...string) error {
	full := append([]string{"-hide_banner", "-loglevel", "error", "-y"}, args...)
	cmd := exec.CommandContext(ctx, "ffmpeg", full...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg: %v: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// jpegThumb renders a small JPEG preview of an image or the first frame of a video.
func jpegThumb(ctx context.Context, path string) []byte {
	out, err := exec.CommandContext(ctx, "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path,
		"-vf", "scale='min(96,iw)':-2", "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "-q:v", "6", "pipe:1").Output()
	if err != nil {
		return nil
	}
	return out
}

func detectMime(path string, head []byte) string {
	if t := mime.TypeByExtension(strings.ToLower(filepath.Ext(path))); t != "" {
		return t
	}
	return http.DetectContentType(head)
}

// SendFile uploads a local file. kind is "auto", "image", "video", "voice", "audio", "document" or "sticker".
func (c *Core) SendFile(ctx context.Context, chat, path, caption, kind string, opts SendOpts) (*hs.Message, error) {
	if err := c.loggedIn(); err != nil {
		return nil, err
	}
	path = strings.TrimPrefix(path, "file://")
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if st.Size() > 2<<30 {
		return nil, errors.New("file is larger than WhatsApp's 2 GB limit")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	head := make([]byte, 512)
	n, _ := io.ReadFull(f, head)
	f.Close()
	mimeType := detectMime(path, head[:n])
	if kind == "" || kind == "auto" {
		switch {
		case strings.HasPrefix(mimeType, "image/") && mimeType != "image/svg+xml":
			kind = "image"
			if mimeType == "image/gif" {
				kind = "video"
			}
		case strings.HasPrefix(mimeType, "video/"):
			kind = "video"
		case strings.HasPrefix(mimeType, "audio/"):
			kind = "audio"
		default:
			kind = "document"
		}
	}
	tmpDir, err := os.MkdirTemp(c.Paths.TmpDir(), "send-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmpDir)
	work := path
	isGif := mimeType == "image/gif"

	// Normalise to formats every WhatsApp client can display.
	switch kind {
	case "image":
		if mimeType != "image/jpeg" {
			work = filepath.Join(tmpDir, "image.jpg")
			if err := ffmpeg(ctx, "-i", path, "-frames:v", "1", "-q:v", "3", work); err != nil {
				return nil, err
			}
			mimeType = "image/jpeg"
		}
	case "video":
		if mimeType != "video/mp4" || isGif {
			work = filepath.Join(tmpDir, "video.mp4")
			args := []string{"-i", path, "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p",
				"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-movflags", "+faststart"}
			if isGif {
				args = append(args, "-an")
			} else {
				args = append(args, "-c:a", "aac", "-b:a", "128k")
			}
			if err := ffmpeg(ctx, append(args, work)...); err != nil {
				return nil, err
			}
			mimeType = "video/mp4"
		}
	case "voice":
		if !strings.HasPrefix(mimeType, "audio/ogg") {
			work = filepath.Join(tmpDir, "voice.ogg")
			if err := ffmpeg(ctx, "-i", path, "-vn", "-ac", "1", "-ar", "48000", "-c:a", "libopus", "-b:a", "32k",
				"-application", "voip", work); err != nil {
				return nil, err
			}
		}
		mimeType = "audio/ogg; codecs=opus"
	case "sticker":
		work = filepath.Join(tmpDir, "sticker.webp")
		if err := ffmpeg(ctx, "-i", path, "-vf",
			"scale=512:512:force_original_aspect_ratio=decrease,format=rgba,pad=512:512:(ow-iw)/2:(oh-ih)/2:color=0x00000000",
			"-c:v", "libwebp", "-lossless", "0", "-q:v", "80", "-loop", "0", "-an", work); err != nil {
			return nil, err
		}
		mimeType = "image/webp"
	}

	data, err := os.ReadFile(work)
	if err != nil {
		return nil, err
	}
	mediaType := map[string]whatsmeow.MediaType{
		"image": whatsmeow.MediaImage, "sticker": whatsmeow.MediaImage, "video": whatsmeow.MediaVideo,
		"voice": whatsmeow.MediaAudio, "audio": whatsmeow.MediaAudio, "document": whatsmeow.MediaDocument,
	}[kind]
	up, err := c.cli.Upload(ctx, data, mediaType)
	if err != nil {
		return nil, fmt.Errorf("upload: %w", err)
	}
	pr := probe(ctx, work)
	ci := c.contextInfo(ctx, chat, opts)
	size := uint64(len(data))
	msg := &waE2E.Message{}
	local := &hs.Message{Type: kind, Text: caption, MediaMime: mimeType, MediaSize: int64(size),
		MediaW: pr.W, MediaH: pr.H, MediaSecs: int(math.Round(pr.Secs))}
	var thumb []byte
	if kind == "image" || kind == "video" {
		thumb = jpegThumb(ctx, work)
	}
	switch kind {
	case "image":
		msg.ImageMessage = &waE2E.ImageMessage{
			Caption: proto.String(caption), Mimetype: proto.String(mimeType),
			URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &size,
			Width: proto.Uint32(uint32(pr.W)), Height: proto.Uint32(uint32(pr.H)),
			JPEGThumbnail: thumb, ContextInfo: ci,
		}
	case "video":
		msg.VideoMessage = &waE2E.VideoMessage{
			Caption: proto.String(caption), Mimetype: proto.String(mimeType),
			URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &size,
			Width: proto.Uint32(uint32(pr.W)), Height: proto.Uint32(uint32(pr.H)),
			Seconds: proto.Uint32(uint32(pr.Secs)), GifPlayback: proto.Bool(isGif),
			JPEGThumbnail: thumb, ContextInfo: ci,
		}
		if isGif {
			local.Type = "gif"
		}
	case "voice", "audio":
		msg.AudioMessage = &waE2E.AudioMessage{
			Mimetype: proto.String(mimeType), URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &size,
			Seconds: proto.Uint32(uint32(math.Round(pr.Secs))), PTT: proto.Bool(kind == "voice"), ContextInfo: ci,
		}
		if kind == "voice" {
			wf := waveform(ctx, work)
			msg.AudioMessage.Waveform = wf
			ints := make([]int, len(wf))
			for i, b := range wf {
				ints[i] = int(b)
			}
			local.Extra = hs.MarshalExtra(map[string]any{"waveform": ints})
		}
		local.Text = ""
	case "sticker":
		msg.StickerMessage = &waE2E.StickerMessage{
			Mimetype: proto.String(mimeType), URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &size,
			Width: proto.Uint32(512), Height: proto.Uint32(512), ContextInfo: ci,
		}
		local.Text = ""
	default:
		name := filepath.Base(path)
		msg.DocumentMessage = &waE2E.DocumentMessage{
			Mimetype: proto.String(mimeType), Title: proto.String(name), FileName: proto.String(name),
			Caption: proto.String(caption), URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &size, ContextInfo: ci,
		}
		local.Type, local.FileName = "document", name
	}

	// Keep a copy in our media dir so the UI can show it immediately.
	dir := filepath.Join(c.Paths.MediaDir(), safeName(chat))
	_ = os.MkdirAll(dir, 0o700)
	keep := filepath.Join(dir, fmt.Sprintf("out-%d%s", time.Now().UnixNano(), extFor(mimeType)))
	if local.FileName != "" {
		keep = filepath.Join(dir, fmt.Sprintf("out-%d-%s", time.Now().UnixNano(), safeName(local.FileName)))
	}
	if os.WriteFile(keep, data, 0o600) == nil {
		local.MediaPath = keep
	}
	if len(thumb) > 0 {
		tp := filepath.Join(c.Paths.ThumbDir(), fmt.Sprintf("out-%d.jpg", time.Now().UnixNano()))
		if os.WriteFile(tp, thumb, 0o600) == nil {
			local.ThumbPath = tp
		}
	}
	if opts.ReplyTo != "" {
		if q, _ := c.Store.GetMessage(ctx, chat, opts.ReplyTo); q != nil {
			local.QuotedID, local.QuotedSender, local.QuotedText = q.ID, q.SenderName, hs.Preview(q)
		}
	}
	return c.sendAndTrack(ctx, chat, msg, local)
}

// waveform computes WhatsApp's 64-sample 0-100 loudness envelope for voice notes.
func waveform(ctx context.Context, path string) []byte {
	pcm, err := exec.CommandContext(ctx, "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path,
		"-ac", "1", "-ar", "8000", "-f", "s16le", "pipe:1").Output()
	if err != nil || len(pcm) < 128 {
		return nil
	}
	samples := len(pcm) / 2
	const bars = 64
	per := samples / bars
	if per == 0 {
		return nil
	}
	vals := make([]float64, bars)
	var peak float64
	for b := 0; b < bars; b++ {
		var sum float64
		for i := 0; i < per; i++ {
			v := float64(int16(binary.LittleEndian.Uint16(pcm[(b*per+i)*2:])))
			sum += math.Abs(v)
		}
		vals[b] = sum / float64(per)
		peak = math.Max(peak, vals[b])
	}
	out := make([]byte, bars)
	for i, v := range vals {
		if peak > 0 {
			out[i] = byte(math.Round(v / peak * 100))
		}
	}
	return out
}

type recording struct {
	chat  string
	path  string
	cmd   *exec.Cmd
	stdin io.WriteCloser
	start time.Time
}

// StartRecording begins capturing a voice note from the default PipeWire/Pulse source.
func (c *Core) StartRecording(ctx context.Context, chat string) error {
	c.mu.Lock()
	if c.recording != nil {
		c.mu.Unlock()
		return errors.New("already recording")
	}
	c.mu.Unlock()
	path := filepath.Join(c.Paths.TmpDir(), fmt.Sprintf("rec-%d.ogg", time.Now().UnixNano()))
	cmd := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "pulse", "-i", "default",
		"-ac", "1", "-ar", "48000", "-c:a", "libopus", "-b:a", "32k", "-application", "voip", path)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	c.mu.Lock()
	c.recording = &recording{chat: chat, path: path, cmd: cmd, stdin: stdin, start: time.Now()}
	c.mu.Unlock()
	_ = c.SetTyping(ctx, chat, false, true)
	c.Emit("recording", map[string]any{"chat": chat, "active": true})
	return nil
}

// StopRecording ends the capture and sends it (send=true) or discards it.
func (c *Core) StopRecording(ctx context.Context, send bool, opts SendOpts) (*hs.Message, error) {
	c.mu.Lock()
	rec := c.recording
	c.recording = nil
	c.mu.Unlock()
	if rec == nil {
		return nil, errors.New("not recording")
	}
	_, _ = rec.stdin.Write([]byte("q"))
	_ = rec.stdin.Close()
	done := make(chan error, 1)
	go func() { done <- rec.cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = rec.cmd.Process.Kill()
	}
	defer os.Remove(rec.path)
	_ = c.SetTyping(ctx, rec.chat, false, false)
	c.Emit("recording", map[string]any{"chat": rec.chat, "active": false})
	if !send {
		return nil, nil
	}
	if time.Since(rec.start) < time.Second {
		return nil, errors.New("voice note too short")
	}
	return c.SendFile(ctx, rec.chat, rec.path, "", "voice", opts)
}
