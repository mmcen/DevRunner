# Devbox all-in-one development environment derived from the DevRunner base stack
ARG BASE_IMAGE=ghcr.io/chaitin/monkeycode-runner/base:bookworm
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="DevRunner Devbox" \
      org.opencontainers.image.source="https://github.com/chaitin/DevRunner" \
      org.opencontainers.image.description="All-in-one development environment with Go, Node.js, and Python"

ARG DEBIAN_FRONTEND=noninteractive
ARG GO_VERSION=1.25.6
ARG NODE_VERSION=22.22.0

ENV GOROOT=/usr/local/go \
    GOPATH=/go \
    GOCACHE=/go/cache \
    PATH=/usr/local/go/bin:/go/bin:${PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        xz-utils \
        htop \
        iputils-ping \
        iproute2 \
        wget \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir -p "${GOPATH}" "${GOCACHE}"; \
    GO_ARCH="$(dpkg --print-architecture)"; \
    case "${GO_ARCH}" in \
        amd64) GO_ARCHIVE="linux-amd64"; GO_SHA256="f022b6aad78e362bcba9b0b94d09ad58c5a70c6ba3b7582905fababf5fe0181a" ;; \
        arm64) GO_ARCHIVE="linux-arm64"; GO_SHA256="738ef87d79c34272424ccdf83302b7b0300b8b096ed443896089306117943dd5" ;; \
        *) echo "Unsupported architecture: ${GO_ARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.${GO_ARCHIVE}.tar.gz" -o /tmp/go.tar.gz; \
    echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c -; \
    tar -C /usr/local -xzf /tmp/go.tar.gz; \
    rm /tmp/go.tar.gz; \
    go install honnef.co/go/tools/cmd/staticcheck@latest; \
    go install mvdan.cc/gofumpt@latest; \
    go install github.com/swaggo/swag/cmd/swag@latest

RUN set -eux; \
    NODE_ARCH="$(dpkg --print-architecture)"; \
    case "${NODE_ARCH}" in \
        amd64) node_arch="x64"; NODE_SHA256="9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37" ;; \
        arm64) node_arch="arm64"; NODE_SHA256="1bf1eb9ee63ffc4e5d324c0b9b62cf4a289f44332dfef9607cea1a0d9596ba6f" ;; \
        *) echo "Unsupported architecture: ${NODE_ARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep " node-v${NODE_VERSION}-linux-${node_arch}.tar.xz$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -C /usr/local --strip-components=1; \
    rm -f "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" SHASUMS256.txt; \
    corepack enable

ENV PIP_BREAK_SYSTEM_PACKAGES=1

RUN pip3 install --no-cache-dir \
    requests \
    flask \
    django \
    beautifulsoup4 \
    scrapy

ENV NODE_VERSION=${NODE_VERSION}

WORKDIR /workspace

# ---------------------------------------------------------------------------
# Autostarted services, kept alive by supervisord (the image CMD).
# The MonkeyCode Firecracker platform cannot run systemd (PID 1 is the
# platform-injected /firecracker-init), so a pure process manager is used;
# see devbox-guide.md. Services:
#   * sshd on port 2222 — root login restricted to the baked-in public key
#   * tun — Cloudflare Tunnel connector, default token baked in at build
# ---------------------------------------------------------------------------

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh /etc/supervisor /var/log/supervisor \
    && ssh-keygen -A

COPY docker/devbox/bookworm/sshd-devbox.conf /etc/ssh/sshd_config.d/00-devbox.conf
COPY docker/devbox/bookworm/authorized_keys /root/.ssh/authorized_keys
RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys

RUN pip3 install --no-cache-dir --break-system-packages supervisor

# Fixed default tunnel token; override at build time with --build-arg TUN_TOKEN=...
ARG TUN_TOKEN=eyJhIjoiNDNjYjI4NGVjMDY5NWM1NDc0ZTczMzE4YWNkYzcxYzAiLCJ0IjoiMTE5YzZjMDMtN2Q1ZS00NDQyLWI0YjEtNDY2NzBhOWUwODU5IiwicyI6Ik9UTmhOMlptWm1VdE4yRTVNaTAwWm1RekxUZ3dNRGN0T1RVeU5EWTVPRE5tT0ROaCJ9

COPY docker/devbox/bookworm/tun.sh /tmp/tun.sh
RUN set -eux; \
    sh /tmp/tun.sh --token "${TUN_TOKEN}" --no-start; \
    rm -f /tmp/tun.sh; \
    test -x /usr/local/lib/tun/tun; \
    grep -q '^CF_TUNNEL_TOKEN=' /etc/tun/env

COPY docker/devbox/bookworm/tun-run.sh /usr/local/bin/tun-run
COPY docker/devbox/bookworm/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod 755 /usr/local/bin/tun-run

CMD ["/usr/local/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
