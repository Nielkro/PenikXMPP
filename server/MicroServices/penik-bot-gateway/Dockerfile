FROM rust:slim as builder
WORKDIR /usr/src/penik-bot-gateway
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /usr/src/penik-bot-gateway/target/release/penik-bot-gateway /app/penik-bot-gateway
RUN chmod +x /app/penik-bot-gateway

ENV BOT_GATEWAY_HOST=0.0.0.0
ENV BOT_GATEWAY_PORT=8086
ENV BOT_GATEWAY_DB_PATH=/data/bot_gateway.db
ENV PROSODY_HOST=127.0.0.1
ENV PROSODY_PORT=5347
ENV COMPONENT_DOMAIN=bot.snikket.penik.ru
ENV COMPONENT_SECRET=penik_bot_gateway_secret_2026
ENV PROSODY_UPLOAD_JID=share.snikket.penik.ru

EXPOSE 8086
CMD ["/app/penik-bot-gateway"]
