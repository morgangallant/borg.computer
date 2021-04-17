package main

import (
	"errors"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/morgangallant/borg.computer/internal/embed"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func port() string {
	if p, ok := os.LookupEnv("PORT"); ok {
		return p
	}
	return "8080"
}

type htmlStripperFS struct{ underlying fs.FS }

func (hs *htmlStripperFS) Open(name string) (fs.File, error) {
	f, err := hs.underlying.Open(name)
	if err != nil && errors.Is(err, fs.ErrNotExist) && !strings.HasSuffix(name, ".html") {
		f, err = hs.underlying.Open(name + ".html")
	}
	return f, err
}

func run() error {
	ws, err := fs.Sub(fs.FS(embed.Embed), "website")
	if err != nil {
		return err
	}
	http.Handle("/", http.FileServer(http.FS(&htmlStripperFS{ws})))
	return http.ListenAndServe(":"+port(), nil)
}
