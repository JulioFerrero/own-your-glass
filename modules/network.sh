OYG_MOD_NETWORK=1

# network.sh — three-layer outbound mitigations for telemetry / ad / cloud
# domains on a rooted LG webOS TV.
#
# Layer 1 (primary): /etc/hosts overlay via bind-mount of a generated file.
#                     For every blocklist domain we emit BOTH `0.0.0.0 <d>`
#                     and `::1 <d>` — a hosts-file sinkhole that maps only
#                     IPv4 leaves the resolver free to return any AAAA
#                     record, which means AAAA-capable clients bypass the
#                     block entirely (verified on device: criteo.com
#                     resolved to 2620:12a:8000::4, doubleclick.net to
#                     2a00:1450:4003:80b::200e through an IPv4-only
#                     sinkhole). The IPv6 mirror closes that gap.
# Layer 2:            blackhole hardcoded public resolvers + opt-in resolv.conf
#                     override; mitigates daemons that bypass /etc/hosts.
# Layer 3 (fallback): per-domain IP blackhole via `ip route add blackhole`,
#                     for daemons that bypass libc `getent` entirely.
#
# Why no iptables: kernel module ip_tables is absent on this device.
# Why no /etc edit: /etc is a read-only overlay.
# Why bind-mount: mount --bind works on /etc on this device (verified).
#
# Blocklist sources (merged in this order, de-duplicated):
#   $OYG_ROOT/etc/blocklist-upstream-safe.txt   (always)
#   $OYG_ROOT/etc/blocklist-oyg.txt — SAFE      (always when OYG_NETWORK_BLOCK=1)
#   $OYG_ROOT/etc/blocklist-oyg.txt — STRICT    (only when OYG_NETWORK_STRICT=1)
#
# Opt-in flags:
#   OYG_NETWORK_BLOCK=1       enable the network module at all (default off)
#   OYG_NETWORK_STRICT=1      include the STRICT (ThinQ / voice / AI / LG) domains
#   OYG_NETWORK_IPBLOCK=1     apply layer 3 (per-IP blackhole routes)
#   OYG_DNS_OVERRIDE=1        write /var/lib/misc/resolv.conf with a chosen
#                             nameserver (default: current default gateway).
#                             Only meaningful alongside layer 2.
#
# Idempotency: every layer remembers what it did (routes added, hosts file
# path, resolv.conf backup path) and only undoes exactly that on restore.

OYG_ETC=${OYG_ETC:-$OYG_ROOT/etc}
HOSTS_GEN="$OYG_ROOT/hosts"
HOSTS_GEN_INSPECT="$OYG_ROOT/hosts.generated"
HOSTS_TARGET=/etc/hosts
RESOLV_TARGET=/var/lib/misc/resolv.conf

ROUTES_KEY=network.routes
RESOLV_ROUTES_KEY=network.resolv_routes
HOSTS_BIND_KEY=network.hosts_bind
RESOLV_BACKUP_KEY=network.resolv_backup
RESOLV_BACKUP_PATH_KEY=network.resolv_target

PUBLIC_RESOLVERS="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 208.67.222.222 208.67.220.220"

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

# Resolve a domain to an A record using libc (getent), fall back to nslookup
# (which bypasses /etc/hosts on this device — see FINDINGS.md).
_mod_network_resolve() {
    domain=$1
    ip=$(getent hosts "$domain" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$ip" ] && have nslookup; then
        ip=$(nslookup "$domain" 2>/dev/null \
            | awk '/^Address: / && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $2; exit}')
    fi
    printf '%s\n' "$ip"
}

# Echo the body of a blocklist file (SAFE only / STRICT only / all),
# stripped of comments and blank lines, one domain per line.
#
# Section markers recognised inside etc/blocklist-oyg.txt:
#   - a line beginning with "# STRICT"  opens a STRICT block
#   - a line beginning with "# SAFE"    re-opens the SAFE block (default)
# Anything outside those markers is SAFE (default).
#
# The upstream file has no section markers — it is treated as all-SAFE.
_mod_network_collect_domains() {
    section=$1  # safe | strict | all
    for f in \
        "$OYG_ETC/blocklist-upstream-safe.txt" \
        "$OYG_ETC/blocklist-oyg.txt" \
    ; do
        [ -r "$f" ] || continue
        awk -v want="$section" '
            function starts_with(s, p) { return substr(s, 1, length(p)) == p }
            BEGIN { in_safe = 1; in_strict = 0 }
            FNR == 1 {
                # Each blocklist file is reset to SAFE at its first line.
                # Files with no explicit section markers (e.g. the upstream
                # SAFE snapshot) are therefore fully SAFE.
                in_safe = 1; in_strict = 0
            }
            {
                line = $0
                sub(/\r$/, "", line)
                if (line ~ /^[[:space:]]*$/) { next }
                trimmed = line
                sub(/^[[:space:]]+/, "", trimmed)

                if (starts_with(trimmed, "#")) {
                    # Pure comment line. Section markers look like:
                    #   "# SAFE section ..."
                    #   "# STRICT section ..."
                    # Inline annotations on a domain line have a domain
                    # token first and will not start with "#".
                    if (starts_with(trimmed, "# STRICT")) { in_safe = 0; in_strict = 1; next }
                    if (starts_with(trimmed, "# SAFE"))   { in_safe = 1; in_strict = 0; next }
                    next
                }
                d = trimmed
                sub(/[[:space:]].*$/, "", d)
                if (d == "") next
                if (want == "safe"   && in_safe)   print d
                if (want == "strict" && in_strict) print d
                if (want == "all"    && (in_safe || in_strict)) print d
            }
        ' "$f"
    done | sort -u
}

# Return 0 if /etc/hosts is currently a bind mount per /proc/mounts.
_mod_network_hosts_is_bind() {
    [ -r /proc/mounts ] || return 1
    awk '{ for (i=2;i<=NF;i++) if ($i == "/etc/hosts") { print $1; exit } }' /proc/mounts \
        | grep -q . && return 0
    return 1
}

_mod_network_default_gw() {
    ip route show default 2>/dev/null \
        | awk '/^default/ { for (i=1;i<=NF;i++) if ($i == "via") { print $(i+1); exit } }'
}

# -----------------------------------------------------------------------------
# Layer 1 — /etc/hosts bind overlay
# -----------------------------------------------------------------------------

mod_network_layer1_harden() {
    [ "${OYG_NETWORK_BLOCK:-0}" = "1" ] || return 0
    [ "$OYG_DRY_RUN" = "1" ] || require_root

    if [ ! -d "$OYG_ETC" ]; then
        err "network: $OYG_ETC not present — blocklists not installed"
        return 1
    fi

    section=safe
    [ "${OYG_NETWORK_STRICT:-0}" = "1" ] && {
        section=all
        warn "network: STRICT section enabled — ThinQ / voice / AI / LG cloud blocked (BREAKS FEATURES)"
    }

    {
        printf '127.0.0.1 localhost\n'
        _mod_network_collect_domains "$section" \
            | awk '{ printf "0.0.0.0 %s\n::1 %s\n", $1, $1 }'
    } >"$HOSTS_GEN" 2>/dev/null
    cp "$HOSTS_GEN" "$HOSTS_GEN_INSPECT" 2>/dev/null || true
    v4_count=$(grep -c '^0\.0\.0\.0 ' "$HOSTS_GEN" 2>/dev/null | tr -d ' ')
    v6_count=$(grep -c '^::1 ' "$HOSTS_GEN" 2>/dev/null | tr -d ' ')
    count=$((v4_count + v6_count))
    ok "network: layer1 — generated $count hosts entries at $HOSTS_GEN (v4=$v4_count v6=$v6_count)"

    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: mount --bind %s %s\n' "$HOSTS_GEN" "$HOSTS_TARGET"
        return 0
    fi

    if _mod_network_hosts_is_bind; then
        ok "network: layer1 — /etc/hosts already bind-mounted; re-binding in place"
        if ! umount "$HOSTS_TARGET" 2>/dev/null; then
            warn "network: layer1 — umount existing bind failed; continuing with mount"
        fi
    fi

    if mount --bind "$HOSTS_GEN" "$HOSTS_TARGET" 2>/dev/null; then
        state_put "$HOSTS_BIND_KEY" "$HOSTS_GEN"
        ok "network: layer1 — bind-mounted $HOSTS_GEN over $HOSTS_TARGET"
    else
        err "network: layer1 — mount --bind failed"
        return 1
    fi
}

mod_network_layer1_restore() {
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    if _mod_network_hosts_is_bind; then
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: umount %s\n' "$HOSTS_TARGET"
        else
            umount "$HOSTS_TARGET" 2>/dev/null \
                && ok "network: layer1 — umounted $HOSTS_TARGET" \
                || warn "network: layer1 — umount failed"
        fi
    else
        ok "network: layer1 — /etc/hosts was not bind-mounted"
    fi
    if [ -f "$HOSTS_GEN" ]; then
        rm -f "$HOSTS_GEN" 2>/dev/null \
            && ok "network: layer1 — removed generated $HOSTS_GEN" \
            || warn "network: layer1 — could not remove $HOSTS_GEN"
    fi
    state_drop "$HOSTS_BIND_KEY"
}

# -----------------------------------------------------------------------------
# Layer 2 — blackhole hardcoded public resolvers (+ optional resolv.conf override)
# -----------------------------------------------------------------------------

mod_network_layer2_harden() {
    [ "${OYG_NETWORK_BLOCK:-0}" = "1" ] || return 0
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    have ip || { err "network: ip command missing"; return 1; }

    warn "network: layer2 — blackholing hardcoded public resolvers (stops TV-bypassed DNS)."
    warn "network: layer2 — DoH/443 and DoT/853 CANNOT be blocked (no netfilter on this device)."

    added=""
    for r in $PUBLIC_RESOLVERS; do
        # NOTE: use `ip route show`, NOT `ip route get`. On this kernel
        # (5.4.268 papikonda, BusyBox ip) `ip route get <ip>` returns
        # "RTNETLINK answers: Invalid argument" for blackhole routes, so a
        # `route get` check always reports "missing" (verified on device).
        if ip route show "$r" 2>/dev/null | grep -q blackhole; then
            ok "network: layer2 — $r already blackholed"
            added="$added $r"
            continue
        fi
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: ip route add blackhole %s\n' "$r"
            added="$added $r"
            continue
        fi
        if ip route add blackhole "$r" 2>/dev/null; then
            ok "network: layer2 — blackhole $r"
            added="$added $r"
        else
            warn "network: layer2 — failed to add blackhole for $r"
        fi
    done
    state_put "$RESOLV_ROUTES_KEY" "$added"

    if [ "${OYG_DNS_OVERRIDE:-0}" = "1" ]; then
        warn "network: layer2 — OYG_DNS_OVERRIDE=1 will rewrite $RESOLV_TARGET"
        target=$RESOLV_TARGET
        if [ ! -e "$target" ]; then
            warn "network: layer2 — $target not present; cannot override"
            return 0
        fi
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: backup %s and write nameserver entry\n' "$target"
            return 0
        fi
        bak="$OYG_BACKUP/resolv.conf.orig"
        if [ ! -e "$bak" ]; then
            if ! cp "$target" "$bak" 2>/dev/null; then
                warn "network: layer2 — cannot back up $target"
                return 0
            fi
            state_put "$RESOLV_BACKUP_KEY" "$bak"
            state_put "$RESOLV_BACKUP_PATH_KEY" "$target"
        fi
        gw=$(_mod_network_default_gw)
        if [ -z "$gw" ]; then
            gw="127.0.0.1"
            warn "network: layer2 — no default gateway found; defaulting nameserver to $gw"
        else
            ok "network: layer2 — using default gateway $gw as nameserver"
        fi
        if {
            printf '# own-your-glass DNS override — restored by `oyg restore`\n'
            printf 'nameserver %s\n' "$gw"
        } >"$target" 2>/dev/null; then
            ok "network: layer2 — wrote $target (nameserver $gw)"
        else
            warn "network: layer2 — failed to write $target"
        fi
    fi
}

mod_network_layer2_restore() {
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    have ip || { err "network: ip missing"; return 1; }
    routes=$(state_get "$RESOLV_ROUTES_KEY")
    for r in $routes; do
        # NOTE: use `ip route show`, NOT `ip route get`. On this kernel
        # (5.4.268 papikonda, BusyBox ip) `ip route get <ip>` returns
        # "RTNETLINK answers: Invalid argument" for blackhole routes, so a
        # `route get` check always reports "missing" (verified on device).
        if ip route show "$r" 2>/dev/null | grep -q blackhole; then
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: ip route del blackhole %s\n' "$r"
            else
                ip route del blackhole "$r" 2>/dev/null \
                    && ok "network: layer2 — removed blackhole $r" \
                    || warn "network: layer2 — failed to del blackhole $r"
            fi
        else
            ok "network: layer2 — $r already not blackholed"
        fi
    done
    state_drop "$RESOLV_ROUTES_KEY"

    bak=$(state_get "$RESOLV_BACKUP_KEY")
    target=$(state_get "$RESOLV_BACKUP_PATH_KEY")
    if [ -n "$bak" ] && [ -n "$target" ] && [ -e "$bak" ]; then
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: cp %s %s\n' "$bak" "$target"
        else
            if cp "$bak" "$target" 2>/dev/null; then
                ok "network: layer2 — restored $target from $bak"
            else
                warn "network: layer2 — restore of $target failed"
            fi
            rm -f "$bak" 2>/dev/null || true
        fi
        state_drop "$RESOLV_BACKUP_KEY"
        state_drop "$RESOLV_BACKUP_PATH_KEY"
    fi
}

# -----------------------------------------------------------------------------
# Layer 3 — per-domain IP blackhole (fallback)
# -----------------------------------------------------------------------------

mod_network_layer3_harden() {
    [ "${OYG_NETWORK_BLOCK:-0}" = "1" ] || return 0
    [ "${OYG_NETWORK_IPBLOCK:-0}" = "1" ] || {
        ok "network: layer3 — skipped (set OYG_NETWORK_IPBLOCK=1 to enable)"
        return 0
    }
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    have ip || { err "network: ip command missing"; return 1; }

    section=all
    [ "${OYG_NETWORK_STRICT:-0}" = "1" ] || section=safe

    warn "network: layer3 — blackhole-routing per resolved IP. CDN IPs ROTATE; refresh often."
    warn "network: layer3 — this is a FALLBACK for daemons that bypass libc and DNS."

    added=""
    _mod_network_collect_domains "$section" >"$OYG_ROOT/.layer3.list" 2>/dev/null
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        ip=$(_mod_network_resolve "$domain")
        if [ -z "$ip" ]; then
            warn "network: layer3 — $domain did not resolve; skipping"
            continue
        fi
        for one in $ip; do
            if ip route show "$one" 2>/dev/null | grep -q blackhole; then
                ok "network: layer3 — $one ($domain) already blackholed"
                added="$added $one"
                continue
            fi
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: ip route add blackhole %s\n' "$one"
                added="$added $one"
                continue
            fi
            if ip route add blackhole "$one" 2>/dev/null; then
                ok "network: layer3 — blackhole $one ($domain)"
                added="$added $one"
            else
                warn "network: layer3 — failed to add blackhole for $one ($domain)"
            fi
        done
    done <"$OYG_ROOT/.layer3.list"
    rm -f "$OYG_ROOT/.layer3.list" 2>/dev/null || true

    state_put "$ROUTES_KEY" "$added"
}

mod_network_layer3_restore() {
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    have ip || { err "network: ip missing"; return 1; }
    routes=$(state_get "$ROUTES_KEY")
    for r in $routes; do
        # NOTE: use `ip route show`, NOT `ip route get`. On this kernel
        # (5.4.268 papikonda, BusyBox ip) `ip route get <ip>` returns
        # "RTNETLINK answers: Invalid argument" for blackhole routes, so a
        # `route get` check always reports "missing" (verified on device).
        if ip route show "$r" 2>/dev/null | grep -q blackhole; then
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: ip route del blackhole %s\n' "$r"
            else
                ip route del blackhole "$r" 2>/dev/null \
                    && ok "network: layer3 — removed blackhole $r" \
                    || warn "network: layer3 — failed to del blackhole $r"
            fi
        else
            ok "network: layer3 — $r already not blackholed"
        fi
    done
    state_drop "$ROUTES_KEY"
}

# -----------------------------------------------------------------------------
# Layer 4 — DNS sinkhole resolver on 127.0.0.2:53, hooked in via a
# bind-mount over /etc/resolv.conf (NOT via ConnMan). The ConnMan route —
# editing /var/lib/connman/<svc>/settings and nudging connmand — took this
# TV off the network for ~30 minutes (see the post-mortem in scripts/dns.sh);
# this toolkit NEVER signals, reloads or restarts connmand. The managed
# resolv.conf lists 127.0.0.2 first and the real upstream as a fallback, so
# DNS survives even if the resolver dies. Start-up ordering: dns.sh starts
# and verifies the resolver BEFORE pointing resolv.conf at it, and an
# auto-revert timer (default 180 s) unmounts the override if an apply is
# never confirmed. Addresses the resolver-bypass gap that lets webOS
# daemons resolve blocked domains even after /etc/hosts is bind-mounted;
# see docs/FINDINGS.md F14g.
#
# Why layer 4 lives here: the resolver's source-of-truth blocklist is
# `$OYG_ROOT/hosts` — the same file layer 1 generates from
# `etc/blocklist-*.txt`. mtime-watched by `dnssink.py`, so re-running
# `oyg harden --only network` after editing the blocklists picks them
# up without restarting the listener.
# -----------------------------------------------------------------------------

DNS_BIND=127.0.0.2
DNS_PORT=53

# Resolve the path of scripts/dns.sh. Both `oyg` and `install.sh` set
# OYG_HERE to the directory containing the loader script. When neither
# is set (e.g. when network.sh is sourced from a one-off test under
# `bash -c`), we fall back to OYG_ROOT, which is the install target.
_dns_bin() {
    if [ -n "${OYG_HERE:-}" ] && [ -r "$OYG_HERE/scripts/dns.sh" ]; then
        printf '%s' "$OYG_HERE/scripts/dns.sh"
        return 0
    fi
    if [ -n "${OYG_ROOT:-}" ] && [ -r "$OYG_ROOT/scripts/dns.sh" ]; then
        printf '%s' "$OYG_ROOT/scripts/dns.sh"
        return 0
    fi
    return 1
}

mod_network_layer4_harden() {
    [ "${OYG_DNS_RESOLVER:-0}" = "1" ] || {
        ok "network: layer4 — skipped (set OYG_DNS_RESOLVER=1 to install the on-device sinkhole resolver)"
        return 0
    }
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    if ! command -v python3 >/dev/null 2>&1; then
        warn "network: layer4 — python3 missing; cannot run the sinkhole"
        return 0
    fi

    bin=$(_dns_bin) || {
        warn "network: layer4 — scripts/dns.sh not found anywhere"
        return 0
    }
    warn "network: layer4 — installing sinkhole resolver on $DNS_BIND:$DNS_PORT and bind-mounting /etc/resolv.conf over it (no connmand interaction; auto-revert timer on apply)."
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: sh %s start\n' "$bin"
        return 0
    fi
    if sh "$bin" start; then
        ok "network: layer4 — dns.sh start succeeded"
    else
        warn "network: layer4 — dns.sh start failed (see $OYG_ROOT/dns.log)"
        return 1
    fi
}

mod_network_layer4_restore() {
    [ "${OYG_DNS_RESOLVER:-0}" = "1" ] && [ "$(state_get dns.applied)" != "1" ] && {
        ok "network: layer4 — not running (state clean); nothing to revert"
        return 0
    }
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    bin=$(_dns_bin) || return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: sh %s stop\n' "$bin"
        return 0
    fi
    if sh "$bin" stop; then
        ok "network: layer4 — dns.sh stop succeeded"
    else
        warn "network: layer4 — dns.sh stop failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# top-level entry points
# -----------------------------------------------------------------------------

mod_network_harden() {
    [ "${OYG_NETWORK_BLOCK:-0}" = "1" ] || {
        warn "network: OYG_NETWORK_BLOCK!=1 — refusing to apply network mitigation by default"
        warn "network: set OYG_NETWORK_BLOCK=1 oyg harden --only network to enable"
        return 0
    }

    [ "$OYG_DRY_RUN" = "1" ] || require_root
    [ "$OYG_DRY_RUN" = "1" ] || ensure_dirs

    warn "network: OYG_NETWORK_BLOCK=1 (enabling all three layers)."
    [ "${OYG_NETWORK_STRICT:-0}" = "1" ] \
        && warn "network: OYG_NETWORK_STRICT=1 — ThinQ / voice / AI / LG cloud will be BLOCKED." \
        || ok "network: STRICT section skipped (set OYG_NETWORK_STRICT=1 to also block ThinQ etc.)"
    [ "${OYG_NETWORK_IPBLOCK:-0}" = "1" ] \
        && warn "network: OYG_NETWORK_IPBLOCK=1 — layer 3 (per-domain IP blackhole) ENABLED." \
        || ok "network: layer 3 disabled (set OYG_NETWORK_IPBLOCK=1 to enable per-IP blackhole)"
    [ "${OYG_DNS_OVERRIDE:-0}" = "1" ] \
        && warn "network: OYG_DNS_OVERRIDE=1 — will rewrite /var/lib/misc/resolv.conf." \
        || ok "network: resolv.conf override disabled (set OYG_DNS_OVERRIDE=1 to enable)"
    [ "${OYG_DNS_RESOLVER:-0}" = "1" ] \
        && warn "network: OYG_DNS_RESOLVER=1 — layer 4 (sinkhole resolver + /etc/resolv.conf override) ENABLED." \
        || ok "network: layer 4 disabled (set OYG_DNS_RESOLVER=1 to install the sinkhole resolver + resolv.conf override)"

    mod_network_layer1_harden || warn "network: layer1 failed"
    mod_network_layer2_harden || warn "network: layer2 failed"
    mod_network_layer3_harden || warn "network: layer3 failed"
    mod_network_layer4_harden || warn "network: layer4 failed"

    state_put "network.applied" "1"
    state_put "network.strict"  "${OYG_NETWORK_STRICT:-0}"
    state_put "network.ipblock" "${OYG_NETWORK_IPBLOCK:-0}"
    state_put "network.dns_override" "${OYG_DNS_OVERRIDE:-0}"
    state_put "network.dns_resolver" "${OYG_DNS_RESOLVER:-0}"
}

mod_network_restore() {
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    have ip || warn "network: ip missing — layer 2 + 3 routes cannot be removed (will leak until reboot)"
    mod_network_layer4_restore
    mod_network_layer3_restore
    mod_network_layer2_restore
    mod_network_layer1_restore
    state_drop "network.applied"
    state_drop "network.strict"
    state_drop "network.ipblock"
    state_drop "network.dns_override"
    state_drop "network.dns_resolver"
}

mod_network_status() {
    # Reality check, NOT a state-key check. The previous implementation
    # trusted `network.applied`, which a later skip from another module
    # (or this module's own opt-in skip path) could overwrite to "0"
    # even when /etc/hosts really was bind-mounted and blackhole routes
    # were really in the kernel. That made `oyg status` lie. We now
    # verify the actual device state and report accordingly:
    #   OK    — at least one layer is provably live on this box
    #   PARTIAL — some layer live, others not (or partial count)
    #   FAIL  — nothing live (e.g. bind lost + no blackhole routes)
    #   N/A   — `ip` command missing, so we cannot verify anything

    if ! have ip; then
        print_status N/A "network: ip command missing — cannot verify layer 2/3 blackhole routes"
        if _mod_network_hosts_is_bind; then
            gen=$(state_get "$HOSTS_BIND_KEY")
            print_status OK "network: layer1 — /etc/hosts bind-mounted from $gen (layer 2/3 not verified, ip missing)"
        else
            print_status FAIL "network: no verification possible (ip missing, /etc/hosts not bind-mounted)"
        fi
        return
    fi

    # Layer 1: real check — is /etc/hosts a mount point right now?
    layer1_ok=0
    if _mod_network_hosts_is_bind; then
        gen=$(state_get "$HOSTS_BIND_KEY")
        print_status OK "network: layer1 — /etc/hosts bind-mounted from $gen"
        layer1_ok=1
    else
        print_status FAIL "network: layer1 — /etc/hosts NOT bind-mounted"
    fi

    # Layer 2: real check — count active blackhole routes via the kernel
    # routing table directly. This catches the situation where another
    # module's run clobbered `network.resolv_routes` to empty but the
    # routes are still in the kernel.
    bh_count=$(ip route show 2>/dev/null | grep -c '^blackhole' || true)
    bh_count=$(printf '%d' "$bh_count" 2>/dev/null || echo 0)
    pub_count=$(printf '%s\n' "$PUBLIC_RESOLVERS" | wc -l | tr -d ' ')
    if [ "$bh_count" = "0" ]; then
        print_status FAIL "network: layer2 — no blackhole routes in kernel routing table"
    elif [ "$bh_count" -lt "$pub_count" ] 2>/dev/null; then
        # Less than the public-resolver floor — partial. (Layer 3 may
        # legitimately push the count higher; this check uses a lower
        # bound, not an upper bound.)
        print_status PARTIAL "network: layer2 — $bh_count blackhole route(s) active (expect at least $pub_count public-resolver blackholes)"
    else
        print_status OK "network: layer2 — $bh_count blackhole route(s) active in kernel"
    fi

    # Layer 3: only meaningful if state shows it was opted in.
    # We still verify reality if the state says it was applied.
    routes=$(state_get "$ROUTES_KEY")
    if [ -z "$routes" ]; then
        if [ "$(state_get "network.ipblock")" = "1" ]; then
            print_status PARTIAL "network: layer3 — opted in but no per-domain routes recorded"
        else
            print_status N/A "network: layer3 — not enabled (set OYG_NETWORK_IPBLOCK=1)"
        fi
    else
        ok_count=0; bad=0
        for r in $routes; do
            if ip route show "$r" 2>/dev/null | grep -q blackhole; then
                ok_count=$((ok_count + 1))
            else
                bad=$((bad + 1))
            fi
        done
        total=$(printf '%s' "$routes" | wc -w | tr -d ' ')
        if [ "$bad" = "0" ]; then
            print_status OK "network: layer3 — $ok_count/$total per-domain blackhole routes active"
        else
            print_status PARTIAL "network: layer3 — $ok_count/$total per-domain blackhole routes active ($bad missing)"
        fi
    fi

    # Optional resolv.conf override. State-key check is fine here —
    # there is no on-device reality check for "is this resolv.conf the
    # one we wrote?" beyond reading the file. We byte-compare the
    # current resolv.conf against the pre-override backup: if they
    # match, the override has been reverted (e.g. by an update) and
    # we report N/A; if they differ, the override is active.
    bak=$(state_get "$RESOLV_BACKUP_KEY")
    target=$(state_get "$RESOLV_BACKUP_PATH_KEY")
    if [ -n "$bak" ] && [ -n "$target" ] && [ -e "$bak" ]; then
        if [ -e "$target" ]; then
            if cmp -s "$bak" "$target" 2>/dev/null; then
                print_status N/A "network: layer2 — resolv.conf override REVERTED (matches pre-override backup)"
            else
                print_status OK "network: layer2 — resolv.conf override active (differs from $bak)"
            fi
        else
            print_status FAIL "network: layer2 — resolv.conf override target $target missing"
        fi
    fi

    # Layer 4 — DNS sinkhole resolver on 127.0.0.2:53 with a resolv.conf
    # override. Reality checks only (never a state-key check, see the
    # F14g finding): is the resolver actually answering on 127.0.0.2,
    # and does the live /etc/resolv.conf actually carry it?
    if [ "$(state_get dns.applied)" != "1" ]; then
        if [ "$(state_get network.dns_resolver)" = "1" ]; then
            print_status PARTIAL "network: layer4 — opted in but dns.applied!=1 (resolv.conf override missing)"
        else
            print_status N/A "network: layer4 — not enabled (set OYG_DNS_RESOLVER=1)"
        fi
    else
        if nslookup -timeout=1 -port=53 example.com "$DNS_BIND" >/dev/null 2>&1 \
            || nslookup -timeout=1 example.com "$DNS_BIND" >/dev/null 2>&1; then
            print_status OK "network: layer4 — resolver answering on $DNS_BIND:$DNS_PORT"
        else
            print_status FAIL "network: layer4 — resolver NOT answering on $DNS_BIND:$DNS_PORT"
        fi
        if grep -q '^nameserver[[:space:]]*127\.0\.0\.2' /etc/resolv.conf 2>/dev/null; then
            print_status OK "network: layer4 — /etc/resolv.conf carries nameserver 127.0.0.2 first"
        else
            print_status FAIL "network: layer4 — /etc/resolv.conf does NOT carry nameserver 127.0.0.2"
        fi
        if grep -q ' /var/lib/misc/resolv.conf ' /proc/self/mountinfo 2>/dev/null \
            || grep -q ' /etc/resolv.conf ' /proc/self/mountinfo 2>/dev/null; then
            print_status OK "network: layer4 — resolv.conf override bind-mounted"
        else
            print_status PARTIAL "network: layer4 — resolv.conf content set but not bind-mounted (watchdog re-asserts)"
        fi
    fi
}