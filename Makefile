PREFIX ?= $(HOME)/.local
BIN = .build/release/audio-relay

.PHONY: build install uninstall clean

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/audio-relay

uninstall:
	rm -f $(PREFIX)/bin/audio-relay

clean:
	rm -rf .build
