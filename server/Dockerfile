FROM docker.io/library/rust:1-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock* ./
COPY sync sync
RUN cargo build --release -p conch-sync

FROM docker.io/library/debian:bookworm-slim
RUN useradd -r -u 10001 conch && mkdir /data && chown conch /data
COPY --from=build /src/target/release/conch-sync /usr/local/bin/conch-sync
USER conch
VOLUME /data
EXPOSE 8080
ENV CONCH_DB=/data/conch-sync.db CONCH_LISTEN=0.0.0.0:8080
CMD ["conch-sync"]
