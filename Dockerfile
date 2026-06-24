# Build the imogen tool server and run it as a small static image.
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /imogen-toolserver ./cmd/imogen-toolserver

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /imogen-toolserver /usr/local/bin/imogen-toolserver
ENV IMOGEN_TOOLSERVER_ADDR=:8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/imogen-toolserver"]
