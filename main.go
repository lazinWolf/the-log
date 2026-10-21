// the-log web — a small local server for the Web UI.
//
//	go build && ./the-log            then open http://127.0.0.1:8484
//	./the-log -addr 127.0.0.1:9000   listen somewhere else
//
// It reads and appends to the same JSON Lines file as the-log.sh
// (THE_LOG_FILE, default ~/the-log.jsonl), one entry per line:
//
//	{"ts":"2026-10-20T19:07:41+05:30","text":"bought new shoes"}
//
// Entries are only ever appended; the file is never rewritten.
package main

import (
	"bufio"
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFiles embed.FS

// Same shape as the-log.sh writes: local time with a +hh:mm offset.
const tsLayout = "2006-01-02T15:04:05-07:00"

type entry struct {
	TS   string `json:"ts"`
	Text string `json:"text"`
}

type logFile struct {
	path string
	mu   sync.Mutex // one append at a time from this process
}

// append writes one entry as a single line with a single write, so it
// interleaves cleanly with the shell's `>>` appends.
func (l *logFile) append(text string) (entry, error) {
	e := entry{TS: time.Now().Format(tsLayout), Text: text}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false) // keep <, > and & readable in the file
	if err := enc.Encode(e); err != nil {
		return entry{}, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	f, err := os.OpenFile(l.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return entry{}, err
	}
	if _, err := f.Write(buf.Bytes()); err != nil {
		f.Close()
		return entry{}, err
	}
	return e, f.Close()
}

// all returns every entry in file order. Lines that aren't valid JSON
// entries are skipped rather than failing the whole read.
func (l *logFile) all() ([]entry, error) {
	entries := []entry{}
	f, err := os.Open(l.path)
	if errors.Is(err, fs.ErrNotExist) {
		return entries, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for sc.Scan() {
		var e entry
		if json.Unmarshal(sc.Bytes(), &e) == nil && e.TS != "" {
			entries = append(entries, e)
		}
	}
	return entries, sc.Err()
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func routes(l *logFile) http.Handler {
	mux := http.NewServeMux()

	web, _ := fs.Sub(webFiles, "web")
	mux.Handle("GET /", http.FileServerFS(web))

	mux.HandleFunc("GET /api/entries", func(w http.ResponseWriter, r *http.Request) {
		entries, err := l.all()
		if err != nil {
			log.Print(err)
			writeError(w, http.StatusInternalServerError, "could not read the log")
			return
		}
		writeJSON(w, http.StatusOK, entries)
	})

	mux.HandleFunc("POST /api/entries", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Text string `json:"text"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			writeError(w, http.StatusBadRequest, "expected {\"text\": \"...\"}")
			return
		}
		text := strings.ReplaceAll(in.Text, "\r\n", "\n")
		if strings.TrimSpace(text) == "" {
			writeError(w, http.StatusBadRequest, "nothing to log")
			return
		}
		e, err := l.append(text)
		if err != nil {
			log.Print(err)
			writeError(w, http.StatusInternalServerError, "could not write to the log")
			return
		}
		writeJSON(w, http.StatusCreated, e)
	})

	// Other websites open in the browser can't post entries or, through
	// DNS rebinding, read them.
	return loopbackHostOnly(http.NewCrossOriginProtection().Handler(mux))
}

// loopbackHostOnly rejects requests whose Host header isn't a loopback
// name, so a page on another domain that resolves to 127.0.0.1 can't
// talk to the server.
func loopbackHostOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil {
			host = r.Host
		}
		ip := net.ParseIP(strings.Trim(host, "[]"))
		if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func logPath() string {
	if p := os.Getenv("THE_LOG_FILE"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatal(err)
	}
	return filepath.Join(home, "the-log.jsonl")
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8484", "address to listen on (keep it on loopback)")
	flag.Parse()

	l := &logFile{path: logPath()}
	log.Printf("the-log: %s → http://%s", l.path, *addr)
	log.Fatal(http.ListenAndServe(*addr, routes(l)))
}
