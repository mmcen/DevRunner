#!/bin/sh
# Start the Cloudflare Tunnel connector in the foreground (supervised entrypoint).
# The default token is baked into the image by the tun.sh installer:
# prefer /etc/tun/env (KEY=VALUE, sourced), fall back to /etc/tun/token.
if [ -s /etc/tun/env ]; then
    . /etc/tun/env
elif [ -s /etc/tun/token ]; then
    CF_TUNNEL_TOKEN="$(cat /etc/tun/token)"
    export CF_TUNNEL_TOKEN
fi
exec /usr/local/lib/tun/tun run
