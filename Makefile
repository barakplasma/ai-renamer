BEND ?= bend
CC = clang
PREFIX ?= /usr/local
LDFLAGS ?=
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
HOST_LIBS = -lcurl
else
HOST_LIBS = -lcurl -lcrypto -ldl
endif

.PHONY: all check verdict test install clean
all: .build/ai-renamer

.build/bend.c: $(wildcard *.bend effects/*.c effects/*.js effects/*.h)
	mkdir -p .build
	$(BEND) main.bend -o $@

.build/ai-renamer: .build/bend.c
	$(CC) -std=gnu11 -I . -O2 -pthread -Wno-deprecated-declarations $(LDFLAGS) $< -lm $(HOST_LIBS) -o $@

check:
	$(BEND) PROOF.bend

verdict:
	$(BEND) PROOF.bend --verdict

test: check all
	$(BEND) tests/FilenameProperties.bend
	python3 -m unittest discover -s tests -v

install: all
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 .build/ai-renamer "$(DESTDIR)$(PREFIX)/bin/"

clean:
	rm -rf .build
