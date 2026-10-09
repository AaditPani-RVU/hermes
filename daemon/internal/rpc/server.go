// Package rpc serves newline-delimited JSON-RPC over a Unix socket.
//
//	→ {"id": 1, "method": "chats.list", "params": {...}}
//	← {"id": 1, "result": ...}  or  {"id": 1, "error": {"message": "..."}}
//	← {"event": "message", "data": {...}}   (only after "events.subscribe")
package rpc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"sync"

	waLog "go.mau.fi/whatsmeow/util/log"
)

type Handler func(ctx context.Context, params json.RawMessage) (any, error)

type Server struct {
	Log      waLog.Logger
	handlers map[string]Handler

	mu      sync.Mutex
	clients map[*client]struct{}
}

type client struct {
	conn       net.Conn
	out        chan []byte
	subscribed bool
	isUI       bool
}

func New(log waLog.Logger) *Server {
	return &Server{Log: log, handlers: map[string]Handler{}, clients: map[*client]struct{}{}}
}

func (s *Server) Register(method string, h Handler) { s.handlers[method] = h }

// UIConnected reports whether any client has identified itself as a UI window.
func (s *Server) UIConnected() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for c := range s.clients {
		if c.isUI {
			return true
		}
	}
	return false
}

func (s *Server) Broadcast(event string, data any) {
	b, err := json.Marshal(map[string]any{"event": event, "data": data})
	if err != nil {
		return
	}
	b = append(b, '\n')
	s.mu.Lock()
	defer s.mu.Unlock()
	for c := range s.clients {
		if !c.subscribed {
			continue
		}
		select {
		case c.out <- b:
		default:
			s.Log.Warnf("RPC client too slow, dropping it")
			c.conn.Close()
		}
	}
}

func (s *Server) Serve(ctx context.Context, path string) error {
	_ = os.Remove(path)
	l, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	_ = os.Chmod(path, 0o600)
	go func() {
		<-ctx.Done()
		l.Close()
		_ = os.Remove(path)
	}()
	for {
		conn, err := l.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go s.handle(ctx, conn)
	}
}

type request struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type rpcError struct {
	Message string `json:"message"`
}

type response struct {
	ID     json.RawMessage `json:"id"`
	Result any             `json:"result,omitempty"`
	Error  *rpcError       `json:"error,omitempty"`
}

func (s *Server) handle(ctx context.Context, conn net.Conn) {
	c := &client{conn: conn, out: make(chan []byte, 1024)}
	s.mu.Lock()
	s.clients[c] = struct{}{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.clients, c)
		s.mu.Unlock()
		conn.Close()
	}()
	go func() {
		w := bufio.NewWriter(conn)
		for b := range c.out {
			if _, err := w.Write(b); err != nil {
				return
			}
			if len(c.out) == 0 {
				if err := w.Flush(); err != nil {
					return
				}
			}
		}
	}()
	defer close(c.out)

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 64*1024), 16<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			s.reply(c, response{Error: &rpcError{"invalid JSON: " + err.Error()}})
			continue
		}
		switch req.Method {
		case "events.subscribe":
			var p struct {
				UI bool `json:"ui"`
			}
			_ = json.Unmarshal(req.Params, &p)
			s.mu.Lock()
			c.subscribed, c.isUI = true, p.UI
			s.mu.Unlock()
			s.reply(c, response{ID: req.ID, Result: true})
			continue
		}
		h, ok := s.handlers[req.Method]
		if !ok {
			s.reply(c, response{ID: req.ID, Error: &rpcError{"unknown method " + req.Method}})
			continue
		}
		// Run each call concurrently so a slow upload doesn't block typing indicators.
		go func(req request) {
			defer func() {
				if r := recover(); r != nil {
					s.Log.Errorf("panic in %s: %v", req.Method, r)
					s.reply(c, response{ID: req.ID, Error: &rpcError{"internal error"}})
				}
			}()
			res, err := h(ctx, req.Params)
			if err != nil {
				s.reply(c, response{ID: req.ID, Error: &rpcError{err.Error()}})
				return
			}
			if res == nil {
				res = true
			}
			s.reply(c, response{ID: req.ID, Result: res})
		}(req)
	}
}

func (s *Server) reply(c *client, r response) {
	b, err := json.Marshal(r)
	if err != nil {
		b, _ = json.Marshal(response{ID: r.ID, Error: &rpcError{err.Error()}})
	}
	b = append(b, '\n')
	defer func() { _ = recover() }() // channel may be closed if the client left
	c.out <- b
}

// Bind decodes params into T, for use inside handlers.
func Bind[T any](raw json.RawMessage) (T, error) {
	var v T
	if len(raw) == 0 || string(raw) == "null" {
		return v, nil
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		return v, errors.New("bad params: " + err.Error())
	}
	return v, nil
}
