package wa

import (
	"testing"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

func TestCleanTranscript(t *testing.T) {
	cases := map[string]string{
		" [BLANK_AUDIO]\n":                      "",
		" Hey, are you coming tonight?\n":       "Hey, are you coming tonight?",
		"(music) okay so\n listen *laughs* bro": "okay so listen bro",
		" haan bhai, kal milte hain [Music]":    "haan bhai, kal milte hain",
	}
	for in, want := range cases {
		if got := cleanTranscript(in); got != want {
			t.Errorf("cleanTranscript(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestVoicePreview(t *testing.T) {
	if got := hs.Preview(&hs.Message{Type: "voice"}); got != "🎤 Voice message" {
		t.Errorf("untranscribed: %q", got)
	}
	if got := hs.Preview(&hs.Message{Type: "voice", Text: "call me back"}); got != "🎤 call me back" {
		t.Errorf("transcribed: %q", got)
	}
}
