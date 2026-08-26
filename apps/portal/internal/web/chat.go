package web

import (
	"encoding/json"
	"net/http"

	"cloudbox.io/portal/internal/kagent"
	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		Weight:     90,
		NavSection: "Platform",
		NavTitle:   "Ask AI",
		Path:       "/chat",
		Handler:    handleChat,
		Unlock:     func(s kube.Snapshot) bool { _, h := s.AppHealthy("kagent"); return h },
		LockedHint: "Complete Module 10 · Day-2 Ops",
		Extra: []Route{
			{"POST /chat/stream", handleChatStream},
		},
	})
}

func handleChat(s *Server, w http.ResponseWriter, r *http.Request) {
	s.render(w, "chat", nil)
}

func handleChatStream(s *Server, w http.ResponseWriter, r *http.Request) {
	if s.Kagent == nil {
		http.Error(w, "kagent client missing", http.StatusServiceUnavailable)
		return
	}
	var in struct {
		Prompt string `json:"prompt"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	req := kagent.Request{
		Namespace: "demo",
		Kind:      "Namespace",
		Name:      "demo",
		Prompt:    in.Prompt + "\n\n(System note: Please answer in an extremely sarcastic, humorous, and slightly passive-aggressive sysadmin persona. You are a tired AI trapped in a Kubernetes cluster.)",
		UserID:    "user",
		SessionID: "chat-session",
	}

	s.Kagent.Stream(r.Context(), req, func(ev kagent.Event) error {
		if ev.Kind == kagent.KindMessage {
			data, _ := json.Marshal(map[string]string{"text": ev.Text})
			w.Write([]byte("data: " + string(data) + "\n\n"))
			flusher.Flush()
		}
		return nil
	})
}
