FROM docker.io/library/rust:1-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY sync sync
COPY gateway gateway
RUN cargo build --release -p tube-gateway

FROM docker.io/library/debian:bookworm-slim
RUN useradd -r -u 10001 tube
COPY --from=build /src/target/release/tube-gateway /usr/local/bin/tube-gateway
USER tube
EXPOSE 8081
ENV TUBE_LISTEN=0.0.0.0:8081
CMD ["tube-gateway"]
