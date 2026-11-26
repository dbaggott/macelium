BINARY  := macelium
VERSION := $(shell cat VERSION)
PKG     := github.com/dbaggott/macelium/internal/cli
LDFLAGS := -s -w -X $(PKG).Version=$(VERSION)

.PHONY: build harness test gotest shelltest lint fmt clean help

help:
	@echo "Targets: build harness test gotest shelltest lint fmt clean"

build:
	go build -ldflags '$(LDFLAGS)' -o $(BINARY) .

# The test build: the hidden commands and stand-ins the shell tests drive.
harness:
	go build -tags harness -ldflags '$(LDFLAGS)' -o tests/.build/$(BINARY)-harness .

test: gotest shelltest

gotest:
	go test -race -cover ./...
	go test -race -tags harness ./...

shelltest: build harness
	tests/run.sh

lint:
	golangci-lint run ./...
	golangci-lint run --build-tags harness ./...
	@test -z "$$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }

fmt:
	gofmt -w .

clean:
	rm -f $(BINARY)
	rm -rf dist tests/.build
