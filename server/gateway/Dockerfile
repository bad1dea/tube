FROM docker.io/library/rust:1-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY sync sync
COPY gateway gateway
RUN cargo build --release -p conch-gateway

FROM docker.io/library/debian:bookworm-slim
RUN useradd -r -u 10001 conch
COPY --from=build /src/target/release/conch-gateway /usr/local/bin/conch-gateway
USER conch
EXPOSE 8081
ENV CONCH_LISTEN=0.0.0.0:8081
CMD ["conch-gateway"]
