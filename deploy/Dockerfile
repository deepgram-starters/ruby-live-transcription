# Stage 1: Build custom Caddy with rate limiting module
FROM golang:1.23-alpine AS caddy-builder
WORKDIR /build
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
RUN xcaddy build v2.9.1 --with github.com/mholt/caddy-ratelimit
# Binary output: /build/caddy

# Stage 2: Build frontend
FROM node:24-slim AS frontend-builder
RUN corepack enable
WORKDIR /build
COPY frontend/package.json frontend/pnpm-lock.yaml ./frontend/
RUN cd frontend && pnpm install --frozen-lockfile
COPY frontend/ ./frontend/
RUN cd frontend && pnpm build
# Inject Caddy template directive for subpath base path
RUN sed -i 's|<head>|<head>\n  <base href="{{ .Req.Header.Get "X-Base-Path" }}">|' ./frontend/dist/index.html

# Stage 3: Install Ruby dependencies
FROM ruby:3.3-alpine AS ruby-builder
WORKDIR /build

# Install build dependencies for native extensions
RUN apk add --no-cache build-base

COPY Gemfile Gemfile.lock ./
RUN mkdir -p .bundle && \
    bundle config set --local deployment true && \
    bundle config set --local without development test && \
    bundle install
COPY app.rb ./
COPY test/ ./test/
RUN DEEPGRAM_API_KEY=test-key bundle exec ruby -Itest test/deepgram_url_test.rb

# Stage 4: Runtime
FROM ruby:3.3-alpine

# Install runtime libraries for native gems and TLS connections to Deepgram.
RUN apk add --no-cache ca-certificates libstdc++ openssl-dev

# Copy custom Caddy binary
COPY --from=caddy-builder /build/caddy /usr/bin/caddy

WORKDIR /app

# Copy Ruby dependencies
COPY --from=ruby-builder /build/vendor/ ./vendor/
COPY --from=ruby-builder /usr/local/bundle/config /usr/local/bundle/config

# Copy application files
COPY Gemfile Gemfile.lock config.ru puma.rb app.rb ./
COPY *.toml sample.env ./

# Copy built frontend
COPY --from=frontend-builder /build/frontend/dist/ ./frontend/dist/

# Copy shared deployment files
COPY deploy/Caddyfile /etc/caddy/Caddyfile
COPY deploy/start.sh ./start.sh
RUN chmod +x ./start.sh

ENV PORT=8081
ENV HOST=0.0.0.0
EXPOSE 8080

ENV BACKEND_CMD="bundle exec puma -C puma.rb"
CMD ["./start.sh"]
