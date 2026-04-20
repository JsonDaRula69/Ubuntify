#!/bin/bash
#
# lib/discover.sh - Hostname discovery and smart resolution
#
# Provides:
#   detect_remote_hosts() - Browse for SSH services via Bonjour/dns-sd
#   resolve_hostname()    - Try .local/.lan suffixes and test SSH connectivity
#
# Usage:
#   source "$LIB_DIR/discover.sh"
#   hosts=$(detect_remote_hosts)
#   resolved=$(resolve_hostname "macpro")
#

[ "${_DISCOVER_SH_SOURCED:-0}" -eq 1 ] && return 0
_DISCOVER_SH_SOURCED=1

# ── Bonjour/dns-sd Host Discovery ──
#
# Browses for _ssh._tcp services on the local network using macOS dns-sd.
# Returns a newline-separated list of discovered hostnames (deduplicated),
# or empty string if none found or dns-sd unavailable.
#
# Timeout: 5 seconds (3 seconds browse + 2 seconds grace)
# In agent mode (--agent), skips discovery and returns empty.
detect_remote_hosts() {
    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        return 0
    fi

    # dns-sd browses the local network; skip in remote mode (wrong network)
    if [ "${DEPLOY_MODE:-local}" != "local" ]; then
        return 0
    fi

    if ! command -v dns-sd >/dev/null 2>&1; then
        log_info "dns-sd not available, skipping Bonjour discovery"
        return 0
    fi

    local tmpfile
    tmpfile="$(mktemp /tmp/macpro-dns-sd.XXXXXX)" || return 0
    local dns_sd_pid=""

    # dns-sd -B fields: Timestamp Add/Remove Flags Interface Domain ServiceType InstanceName
    dns-sd -B _ssh._tcp local. > "$tmpfile" 2>/dev/null &
    dns_sd_pid=$!

    sleep 3

    if [ -n "$dns_sd_pid" ]; then
        kill "$dns_sd_pid" 2>/dev/null || true
        wait "$dns_sd_pid" 2>/dev/null || true
    fi

    local hosts=""
    local name=""
    while IFS= read -r line; do
        case "$line" in
            "Browse reply"*) continue ;;
            "Timestamp"*) continue ;;
            "") continue ;;
        esac

        name="$(echo "$line" | awk '{print $NF}')"
        [ -z "$name" ] && continue

        if echo "$hosts" | grep -qxF "$name"; then
            continue
        fi

        if [ -z "$hosts" ]; then
            hosts="$name"
        else
            hosts="$hosts"$'\n'"$name"
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"

    if [ -n "$hosts" ]; then
        printf '%s\n' "$hosts"
        log_info "Bonjour discovery found SSH services: $(echo "$hosts" | tr '\n' ' ')"
    else
        log_info "Bonjour discovery found no SSH services"
    fi
}

# ── Smart Hostname Resolution ──
#
# Takes a hostname (or IP) and tries multiple formats to find one that
# responds to SSH. Returns the first working format, or the original
# input if nothing works.
#
# Formats tried (in order):
#   1. Original input as-is (e.g., "192.168.1.5" or "macpro.local")
#   2. Append .local (e.g., "macpro" → "macpro.local")
#   3. Append .lan   (e.g., "macpro" → "macpro.lan")
#
# IP addresses are passed through immediately without suffix attempts.
# Returns the resolved hostname as a string on stdout.
#
# This is a PURE FUNCTION — it does NOT modify TARGET_HOST or any global.
resolve_hostname() {
    local input="$1"
    local timeout="${2:-5}"

    if echo "$input" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$input"
        return 0
    fi

    local candidates=""

    if echo "$input" | grep -q '\.'; then
        candidates="$input"
        local base
        base="$(echo "$input" | sed 's/\.[^.]*$//')"
        if [ "$input" != "${base}.local" ]; then
            candidates="$candidates"$'\n'"${base}.local"
        fi
        if [ "$input" != "${base}.lan" ]; then
            candidates="$candidates"$'\n'"${base}.lan"
        fi
    else
        candidates="$input"$'\n'"${input}.local"$'\n'"${input}.lan"
    fi

    local candidate
    local tried=""
    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        tried="${tried:+$tried, }$candidate"

        log_info "Trying SSH connectivity to: $candidate"
        if ssh -o ConnectTimeout="$timeout" -o BatchMode=yes \
             -o StrictHostKeyChecking=no \
             "$candidate" "echo ok" >/dev/null 2>&1; then
            log_info "SSH connectivity confirmed: $candidate"
            echo "$candidate"
            return 0
        fi
    done <<< "$candidates"

    log_warn "No SSH response from any hostname format: $tried"
    echo "$input"
    return 1
}