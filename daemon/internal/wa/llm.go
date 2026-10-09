package wa

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// ---- Local LLM (Ollama) ----
//
// Translation, catch-up summaries and digest gists run on a local Ollama server, so chats never
// leave the machine. Nothing here sends anything to anyone; results are only shown to you.
// kv llm_url (default http://127.0.0.1:11434), llm_model ("" = pick a small installed model).

const defaultLLMURL = "http://127.0.0.1:11434"

// Small, multilingual models first: these handle Hinglish and run on a 4 GB GPU.
var preferredModels = []string{"gemma3:4b", "gemma3", "qwen2.5:3b", "llama3.2:3b", "gemma4:e4b", "qwen3:4b", "qwen3:8b", "llama3.1:8b"}

func (c *Core) llmURL(ctx context.Context) string {
	if u := c.Store.GetKV(ctx, "llm_url"); u != "" {
		return strings.TrimRight(u, "/")
	}
	return defaultLLMURL
}

type LLMStatus struct {
	Available bool     `json:"available"`
	URL       string   `json:"url"`
	Model     string   `json:"model"`  // the one that will be used
	Chosen    string   `json:"chosen"` // kv llm_model ("" = automatic)
	Models    []string `json:"models"`
	Enabled   bool     `json:"enabled"` // kv llm != off
	Error     string   `json:"error,omitempty"`
}

func (c *Core) LLMStatus(ctx context.Context) *LLMStatus {
	st := &LLMStatus{URL: c.llmURL(ctx), Chosen: c.Store.GetKV(ctx, "llm_model"), Models: []string{},
		Enabled: c.Store.GetKV(ctx, "llm") != "off"}
	models, err := c.llmModels(ctx)
	if err != nil {
		st.Error = "Ollama isn't running at " + st.URL
		return st
	}
	st.Models = models
	st.Model = pickModel(st.Chosen, models)
	st.Available = st.Model != ""
	if !st.Available {
		st.Error = "No models installed; try: ollama pull gemma3:4b"
	}
	return st
}

func pickModel(chosen string, models []string) string {
	has := map[string]bool{}
	for _, m := range models {
		has[m] = true
		has[strings.TrimSuffix(m, ":latest")] = true
	}
	if chosen != "" && has[chosen] {
		return chosen
	}
	for _, p := range preferredModels {
		if has[p] {
			return p
		}
	}
	for _, m := range models {
		if !strings.Contains(m, "embed") {
			return m
		}
	}
	return ""
}

func (c *Core) llmModels(ctx context.Context) ([]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", c.llmURL(ctx)+"/api/tags", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var tags struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tags); err != nil {
		return nil, err
	}
	out := []string{}
	for _, m := range tags.Models {
		out = append(out, m.Name)
	}
	return out, nil
}

var thinkBlock = regexp.MustCompile(`(?s)<think>.*?</think>`)

// llmChat runs one prompt. onChunk (optional) receives the text so far as it streams.
func (c *Core) llmChat(ctx context.Context, system, prompt string, maxTokens int, onChunk func(string)) (string, error) {
	if c.Store.GetKV(ctx, "llm") == "off" {
		return "", errors.New("AI features are turned off in Settings")
	}
	st := c.LLMStatus(ctx)
	if !st.Available {
		return "", errors.New(st.Error)
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	options := map[string]any{"num_ctx": ctxSize(system, prompt, maxTokens), "num_predict": maxTokens, "temperature": 0.2}
	// All layers on the GPU: on a 4 GB card Ollama's own estimate leaves half of a 4B model on the CPU,
	// which halves the speed. If the card really is full, fall back to Ollama's split.
	gpuAll := c.Store.GetKV(ctx, "llm_gpu") != "auto"
	if gpuAll {
		options["num_gpu"] = 999
	}
	resp, err := c.llmPost(ctx, st, system, prompt, options)
	if err != nil && gpuAll {
		c.Log.Warnf("LLM with all layers on GPU failed (%v), retrying with Ollama's split", err)
		delete(options, "num_gpu")
		resp, err = c.llmPost(ctx, st, system, prompt, options)
	}
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var sb strings.Builder
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	lastEmit := time.Time{}
	for sc.Scan() {
		var chunk struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
			Done  bool   `json:"done"`
			Error string `json:"error"`
		}
		if json.Unmarshal(sc.Bytes(), &chunk) != nil {
			continue
		}
		if chunk.Error != "" {
			return "", fmt.Errorf("ollama: %s", chunk.Error)
		}
		sb.WriteString(chunk.Message.Content)
		if onChunk != nil && time.Since(lastEmit) > 120*time.Millisecond {
			onChunk(cleanLLM(sb.String()))
			lastEmit = time.Now()
		}
		if chunk.Done {
			break
		}
	}
	if err := sc.Err(); err != nil {
		return "", err
	}
	out := cleanLLM(sb.String())
	if onChunk != nil {
		onChunk(out)
	}
	return out, nil
}

func (c *Core) llmPost(ctx context.Context, st *LLMStatus, system, prompt string, options map[string]any) (*http.Response, error) {
	body, _ := json.Marshal(map[string]any{
		"model": st.Model,
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": prompt},
		},
		"stream":     true,
		"keep_alive": "10m",
		"options":    options,
	})
	req, _ := http.NewRequestWithContext(ctx, "POST", st.URL+"/api/chat", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ollama: %w", err)
	}
	if resp.StatusCode != 200 {
		defer resp.Body.Close()
		var e struct {
			Error string `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&e)
		return nil, fmt.Errorf("ollama: %s", e.Error)
	}
	return resp, nil
}

// ctxSize fits the context window to the prompt (≈3 characters per token for chat text), in steps
// of 1024 so Ollama can keep reusing a loaded model. A smaller window leaves more room on the GPU.
func ctxSize(system, prompt string, maxTokens int) int {
	need := (len(system)+len(prompt))/3 + maxTokens + 256
	n := (need + 1023) / 1024 * 1024
	return min(max(n, 2048), 8192)
}

func cleanLLM(s string) string {
	s = thinkBlock.ReplaceAllString(s, "")
	if i := strings.Index(s, "<think>"); i >= 0 { // still thinking
		s = s[:i]
	}
	return strings.TrimSpace(s)
}
