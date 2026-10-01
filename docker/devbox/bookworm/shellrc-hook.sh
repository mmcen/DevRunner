# DevRunner devbox autostart hook for interactive shells (bash and zsh).
# Mirrors /etc/profile.d/00-devbox-autostart.sh for non-login shells.
if [ -x /usr/local/bin/devbox-autostart ] && [ -z "$DEVBOX_AUTOSTARTED" ]; then
    export DEVBOX_AUTOSTARTED=1
    (/usr/local/bin/devbox-autostart >/dev/null 2>&1 &)
fi
