# syntax=docker/dockerfile:1

FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod ./
COPY greeter.go ./
RUN CGO_ENABLED=0 go build -o /out/greeter .

FROM gcr.io/distroless/static-debian12
COPY --from=builder /out/greeter /greeter
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/greeter"]
