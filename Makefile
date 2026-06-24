.PHONY: build test tidy run vet fmt

build:
	go build ./...

test:
	go test ./...

tidy:
	go mod tidy

vet:
	go vet ./...

fmt:
	gofmt -l -w .

run:
	go run ./cmd/imogen-toolserver
