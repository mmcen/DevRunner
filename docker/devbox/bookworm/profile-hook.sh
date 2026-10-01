# DevRunner devbox: bring up sshd/tun/sbox on shell login (idempotent,
# non-blocking; also spawns the background watchdog). The platform may not
# run the image CMD, so shell-login is the reliable autostart trigger.
if [ -x /usr/local/bin/devbox-autostart ] && [ -z "$DEVBOX_AUTOSTARTED" ]; then
    export DEVBOX_AUTOSTARTED=1
    (/usr/local/bin/devbox-autostart >/dev/null 2>&1 &)
fi
