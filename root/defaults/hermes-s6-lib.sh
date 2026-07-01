#!/usr/bin/with-contenv bash
# Shared helpers for /run/service Hermes slots (gateway + dashboard).

hermes_fix_scandir_perms() {
    local scandir="/run/service"
    chown abc:abc "${scandir}" 2>/dev/null || true
    if [ -d "${scandir}/.s6-svscan" ]; then
        for entry in control lock; do
            if [ -e "${scandir}/.s6-svscan/${entry}" ]; then
                chown abc:abc "${scandir}/.s6-svscan/${entry}" 2>/dev/null || true
            fi
        done
    fi
}

hermes_seed_supervise() {
    local dir="$1"
    mkdir -p "${dir}/event" "${dir}/supervise/event" "${dir}/supervise"
    chmod 3730 "${dir}/event" "${dir}/supervise/event" 2>/dev/null || true
    chmod 755 "${dir}/supervise"
    if [ ! -p "${dir}/supervise/control" ]; then
        mkfifo "${dir}/supervise/control"
        chmod 660 "${dir}/supervise/control"
    fi
    chown -R abc:abc "${dir}/event" "${dir}/supervise" 2>/dev/null || true
    chown abc:abc "${dir}/supervise/control" 2>/dev/null || true
}

hermes_start_slot() {
    local slot="$1"
    local path="/run/service/${slot}"
    [ -d "${path}" ] || return 1
    rm -f "${path}/down"
    hermes_seed_supervise "${path}"
    hermes_seed_supervise "${path}/log"
    hermes_fix_scandir_perms
    if command -v s6-svscanctl >/dev/null 2>&1; then
        s6-svscanctl -a /run/service 2>/dev/null || true
    fi
    s6-svc -u "${path}" 2>/dev/null || return 1
    return 0
}
