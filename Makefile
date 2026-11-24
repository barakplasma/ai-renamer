BEND ?= bend
GO ?= go
CC = clang
PREFIX ?= /usr/local
LDFLAGS ?=
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
HOST_LIBS = -framework CoreFoundation -framework Security -framework SystemConfiguration -framework CoreServices -lresolv
else
HOST_LIBS = -ldl -lresolv
endif

.PHONY: all check verdict test install clean
all: .build/ai-renamer

.build/bend.c: main.bend Core.bend Host.bend Options.bend Rollback.bend bridge.c bridge.js
	mkdir -p .build
	$(BEND) main.bend -o $@

.build/host.a: go.mod $(wildcard native/*.go native/*.c)
	mkdir -p .build
	CGO_ENABLED=1 CC="$(CC)" $(GO) build -buildvcs=false -trimpath -buildmode=c-archive -o $@ ./native

.build/ai-renamer: .build/bend.c .build/host.a
	$(CC) -std=gnu11 -O2 -pthread $(LDFLAGS) $^ -lm $(HOST_LIBS) -o $@

check:
	$(BEND) PROOF.bend

verdict:
	$(BEND) PROOF.bend --verdict

test: check all
	CC="$(CC)" $(GO) test ./native
	python3 -m unittest discover -s tests -v

install: all
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 .build/ai-renamer "$(DESTDIR)$(PREFIX)/bin/"

clean:
	rm -rf .build
