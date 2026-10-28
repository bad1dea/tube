FROM docker.io/library/rust:1-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY sync sync
COPY gateway gateway
RUN cargo build --release -p tube-sync

FROM docker.io/library/debian:bookworm-slim
RUN useradd -r -u 10001 tube && mkdir /data && chown tube /data
COPY --from=build /src/target/release/tube-sync /usr/local/bin/tube-sync
USER tube
VOLUME /data
EXPOSE 8080
ENV TUBE_DB=/data/tube-sync.db TUBE_LISTEN=0.0.0.0:8080
CMD ["tube-sync"]
