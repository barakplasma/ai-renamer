BEND ?= bend
PREFIX ?= /usr/local

.PHONY: all check test install clean

all: .build/ai-renamer

.build/ai-renamer: main.bend Core.bend Host.bend Options.bend
	mkdir -p .build
	$(BEND) main.bend -o $@

check:
	$(BEND) PROOF.bend

test: check all
	python3 -m unittest discover -s tests -v

install: all
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 .build/ai-renamer host/renamer-host "$(DESTDIR)$(PREFIX)/bin/"

clean:
	rm -rf .build
