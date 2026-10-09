package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const intelUsage = `
Intelligence (local only):
  hermes catchup <chat> [--last N]    summarise unread (or the last N) messages with the local LLM
  hermes digest <chat> <minutes|off>  batch a busy chat's notifications into one roundup
  hermes ai                           OCR / local-model status
`

// intelCommand handles the intelligence commands; handled=false means it isn't one of them.
func intelCommand(c *client, cmd string, rest []string) (handled bool, err error) {
	switch cmd {
	case "catchup":
		f, pos := splitFlags(rest)
		if len(pos) != 1 {
			return true, errors.New("usage: hermes catchup <chat> [--last N]")
		}
		jid, _, err := c.resolveChat(pos[0])
		if err != nil {
			return true, err
		}
		params := map[string]any{"chat": jid, "scope": "unread"}
		if n := f["last"]; n != "" {
			v, err := strconv.Atoi(n)
			if err != nil {
				return true, errors.New("--last takes a number")
			}
			params["scope"], params["n"] = "recent", v
		}
		var out string
		if err := c.call("chats.summarize", params, &out); err != nil {
			return true, err
		}
		fmt.Println(out)
	case "digest":
		if len(rest) != 2 {
			return true, errors.New("usage: hermes digest <chat> <minutes|off>")
		}
		jid, name, err := c.resolveChat(rest[0])
		if err != nil {
			return true, err
		}
		mins := 0
		if rest[1] != "off" && rest[1] != "0" {
			if mins, err = strconv.Atoi(strings.TrimSuffix(rest[1], "m")); err != nil || mins < 5 {
				return true, errors.New("minutes must be a number ≥ 5, or off")
			}
		}
		if err := c.call("chats.setDigest", map[string]any{"chat": jid, "minutes": mins}, nil); err != nil {
			return true, err
		}
		if mins == 0 {
			fmt.Println("Digest off for", name)
		} else {
			fmt.Printf("%s: one roundup every %d min (mentions still notify right away)\n", name, mins)
		}
	case "ai":
		var st struct {
			OCRInstalled bool `json:"ocrInstalled"`
			OCR          bool `json:"ocr"`
			LLM          struct {
				Available bool     `json:"available"`
				Model     string   `json:"model"`
				Models    []string `json:"models"`
				Enabled   bool     `json:"enabled"`
				Error     string   `json:"error"`
			} `json:"llm"`
			TranslateLang string         `json:"translateLang"`
			Digest        map[string]int `json:"digest"`
		}
		if err := c.call("intel.get", nil, &st); err != nil {
			return true, err
		}
		switch {
		case !st.OCRInstalled:
			fmt.Println("OCR:        not set up (run hermes-ocr-setup)")
		case !st.OCR:
			fmt.Println("OCR:        off")
		default:
			fmt.Println("OCR:        on")
		}
		switch {
		case !st.LLM.Available:
			fmt.Println("Local LLM: ", st.LLM.Error)
		case !st.LLM.Enabled:
			fmt.Println("Local LLM:  off")
		default:
			fmt.Printf("Local LLM:  %s (of %s)\n", st.LLM.Model, strings.Join(st.LLM.Models, ", "))
		}
		fmt.Println("Translate:  into", st.TranslateLang)
		fmt.Printf("Digests:    %d chats\n", len(st.Digest))
	default:
		return false, nil
	}
	return true, nil
}
