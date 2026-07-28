# syntax=docker/dockerfile:1

FROM ghcr.io/bare-devcontainer/zig:0.16.0-bookworm AS build

USER root
RUN apt-get update && apt-get install --yes --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        libicu-dev \
        libonig-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        pkg-config \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# PHP changes only when its source version or configure options change. Build it
# in a separate layer so application-only changes reuse the expensive runtime.
COPY build.zig build.zig.zon ./
RUN zig build php-bootstrap -Doptimize=ReleaseSafe

COPY . .
RUN zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install --yes --no-install-recommends \
        ca-certificates \
        libgcc-s1 \
        libicu72 \
        libonig5 \
        libsodium23 \
        libsqlite3-0 \
        libssl3 \
        libstdc++6 \
        libxml2 \
        zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 frankenphp

# PHP is included so Laravel's Artisan commands can launch FrankenPHP.
COPY --from=build /src/.phpsrc/embed/bin/php /usr/local/bin/php
COPY --from=build /src/zig-out/bin/frankenphp /usr/local/bin/frankenphp

WORKDIR /app
USER frankenphp
EXPOSE 8080
CMD ["frankenphp", "run", "--root", "public", "--port", "8080"]
