FROM rust:1.85-bookworm AS builder

WORKDIR /app
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/target/release/penik-stickers-rs /app/penik-stickers-rs

ENV STICKERS_HOST=0.0.0.0
ENV STICKERS_PORT=8085
ENV STICKERS_DB_PATH=/data/stickers.db
ENV STICKERS_STORAGE_DIR=/data/stickers

EXPOSE 8085

CMD ["/app/penik-stickers-rs"]
