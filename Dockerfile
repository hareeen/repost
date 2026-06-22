# syntax=docker/dockerfile:1.7

FROM ghcr.io/gleam-lang/gleam:v1.15.4-erlang-alpine AS builder

WORKDIR /app

COPY gleam.toml manifest.toml ./
RUN gleam deps download

COPY src/ ./src/
RUN gleam export erlang-shipment

FROM erlang:28-alpine
RUN apk add --no-cache ca-certificates && update-ca-certificates

WORKDIR /app
COPY --from=builder /app/build/erlang-shipment ./

RUN addgroup -S repost && adduser -S -G repost repost && chown -R repost:repost /app
USER repost

EXPOSE 4000

ENTRYPOINT ["/app/entrypoint.sh", "run"]
