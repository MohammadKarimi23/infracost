BINARY := infracost
PKG := github.com/infracost/infracost/cmd/infracost
TERRAFORM_PROVIDER_INFRACOST_VERSION := latest
VERSION := $(shell scripts/get_version.sh HEAD $(NO_DIRTY))
LD_FLAGS := -ldflags="-X 'github.com/infracost/infracost/internal/version.Version=$(VERSION)'"
BUILD_FLAGS := $(LD_FLAGS) -v

DEV_ENV := dev
ifdef INFRACOST_ENV
	DEV_ENV := $(INFRACOST_ENV)
endif

.PHONY: deps run build windows linux darwin build_all install release install_provider clean test fmt lint

deps:
	go mod download

run:
	env INFRACOST_ENV=$(DEV_ENV) go run $(LD_FLAGS) $(PKG) $(ARGS)

build:
	CGO_ENABLED=0 go build $(BUILD_FLAGS) -o build/$(BINARY) $(PKG)

windows:
	env GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build $(BUILD_FLAGS) -o build/$(BINARY)-windows-amd64 $(PKG)

linux:
	env GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build $(BUILD_FLAGS) -o build/$(BINARY)-linux-amd64 $(PKG)

darwin:
	env GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build $(BUILD_FLAGS) -o build/$(BINARY)-darwin-amd64 $(PKG)

build_all: build windows linux darwin

install:
	CGO_ENABLED=0 go install $(BUILD_FLAGS) $(PKG)

release: build_all
	cd build; tar -czf $(BINARY)-windows-amd64.tar.gz $(BINARY)-windows-amd64
	cd build; tar -czf $(BINARY)-linux-amd64.tar.gz $(BINARY)-linux-amd64
	cd build; tar -czf $(BINARY)-darwin-amd64.tar.gz $(BINARY)-darwin-amd64

install_provider:
	scripts/install_provider.sh $(TERRAFORM_PROVIDER_INFRACOST_VERSION)

clean:
	go clean
	rm -rf build/$(BINARY)*

test:
	INFRACOST_LOG_LEVEL=warn go test -timeout 20m $(LD_FLAGS) ./... $(or $(ARGS), -v -cover)

fmt:
	go fmt ./...

lint:
	golangci-lint run
