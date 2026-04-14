#!/bin/bash
#
# lib/tui.sh - Text User Interface (TUI) module for deployment scripts
#
# Provides menu primitives that work with dialog, whiptail, or raw bash read.
# Auto-detects available backend at source time.
#

[ "${_TUI_SH_SOURCED:-0}" -eq 1 ] && return 0
_TUI_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"

readonly TUI_BACKTITLE="Mac Pro 2013 Ubuntu Server"

## Backend Detection

if command -v dialog >/dev/null 2>&1; then
    readonly TUI_BACKEND="dialog"
    readonly TUI_HAS_GAUGE=1
    readonly TUI_HAS_TAILBOX=1
elif command -v whiptail >/dev/null 2>&1; then
    readonly TUI_BACKEND="whiptail"
    readonly TUI_HAS_GAUGE=0
    readonly TUI_HAS_TAILBOX=0
else
    readonly TUI_BACKEND="raw"
    readonly TUI_HAS_GAUGE=0
    readonly TUI_HAS_TAILBOX=0
fi

## Helper Functions

_tui_get_size() {
    local cols lines
    cols=$(tput cols 2>/dev/null || echo 80)
    lines=$(tput lines 2>/dev/null || echo 24)
    local width=$((cols - 4))
    local height=$((lines - 4))
    [ "$width" -gt 78 ] && width=78
    [ "$height" -gt 22 ] && height=22
    [ "$width" -lt 40 ] && width=40
    [ "$height" -lt 10 ] && height=10
    echo "$height $width"
}

_tui_cleanup() {
    local tmpfile="$1"
    [ -n "$tmpfile" ] && [ -f "$tmpfile" ] && rm -f "$tmpfile"
}

_tui_mktemp() {
    mktemp 2>/dev/null || echo "/tmp/tui_$$"
}

## Menu Primitives

tui_menu() {
    local title="$1"
    local description="$2"
    shift 2

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        local selection=""
        local options=""
        local opt_count=0
        local first_tag=""
        while [ $# -ge 2 ]; do
            local tag="$2"
            [ -z "$first_tag" ] && first_tag="$tag"
            [ -n "$options" ] && options="${options},"
            options="${options}${tag}"
            shift 2
            opt_count=$((opt_count + 1))
        done

        if [ -n "${AGENT_MENU_SELECTION:-}" ]; then
            selection="$AGENT_MENU_SELECTION"
        elif [ -n "$first_tag" ]; then
            selection="$first_tag"
        fi

        if [ -n "$selection" ]; then
            agent_output "menu" "$title" "$selection"
            echo "$selection"
            return 0
        else
            agent_output "menu_options" "$title" "" "options" "$options"
            return 1
        fi
    fi

    local size
    size=$(_tui_get_size)
    local height
    height=$(echo "$size" | cut -d' ' -f1)
    local width
    width=$(echo "$size" | cut -d' ' -f2)
    local tmpfile
    tmpfile=$(_tui_mktemp)
    trap '_tui_cleanup '"'$tmpfile'"'' EXIT

    if [ "$TUI_BACKEND" = "dialog" ]; then
        local items=()
        while [ $# -ge 2 ]; do
            items+=("$2" "$1" "")
            shift 2
        done
        if dialog --colors --backtitle "$TUI_BACKTITLE" --title "$title" --menu "\Z3$description\Zn" "$height" "$width" 10 "${items[@]}" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            trap - ERR
            echo "$result"
            return 0
        else
            rm -f "$tmpfile"
            trap - ERR
            return 1
        fi
    elif [ "$TUI_BACKEND" = "whiptail" ]; then
        local items=()
        while [ $# -ge 2 ]; do
            items+=("$2" "$1" "OFF")
            shift 2
        done
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --radiolist "$description" "$height" "$width" 10 "${items[@]}" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            trap - ERR
            echo "$result"
            return 0
        else
            rm -f "$tmpfile"
            trap - ERR
            return 1
        fi
    else
        trap - ERR
        echo ""
        echo "=== $title ==="
        echo "$description"
        echo ""
        local idx=1
        local tags=()
        while [ $# -ge 2 ]; do
            echo "  $idx) $1"
            tags+=("$2")
            shift 2
            idx=$((idx + 1))
        done
        echo ""
        local choice
        while true; do
            read -rp "Enter choice [1-$((idx - 1))]: " choice
            case "$choice" in
                ''|*[!0-9]*)
                    echo "Invalid choice. Please enter a number."
                    continue
                    ;;
            esac
            if [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
                echo "${tags[$((choice - 1))]}"
                return 0
            fi
            echo "Invalid choice."
        done
    fi
}

tui_confirm() {
    local title="$1"
    local message="$2"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        if [ "${CONFIRM_YES:-0}" -eq 1 ]; then
            agent_output "confirm" "$title" "yes"
            return 0
        else
            agent_output "confirm" "$title" "no"
            return 1
        fi
    fi

    local size
    size=$(_tui_get_size)
    local height
    height=$(echo "$size" | cut -d' ' -f1)
    local width
    width=$(echo "$size" | cut -d' ' -f2)

    if [ "$TUI_BACKEND" = "dialog" ]; then
        if dialog --colors --backtitle "$TUI_BACKTITLE" --title "$title" --yesno "\Z3$message\Zn" "$height" "$width" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    elif [ "$TUI_BACKEND" = "whiptail" ]; then
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --yesno "$message" "$height" "$width" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        echo ""
        echo "=== $title ==="
        echo "$message"
        echo ""
        local response
        while true; do
            read -rp "Proceed? (yes/no): " response
            case "$response" in
                yes|y|Y) return 0 ;;
                no|n|N) return 1 ;;
            esac
            echo "Please enter 'yes' or 'no'."
        done
    fi
}

tui_msgbox() {
    local title="$1"
    local message="$2"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        agent_output "msgbox" "$title" "$message"
        return 0
    fi

    local size
    size=$(_tui_get_size)
    local height
    height=$(echo "$size" | cut -d' ' -f1)
    local width
    width=$(echo "$size" | cut -d' ' -f2)

    if [ "$TUI_BACKEND" = "dialog" ]; then
        dialog --colors --backtitle "$TUI_BACKTITLE" --title "$title" --msgbox "\Z3$message\Zn" "$height" "$width" 2>/dev/null || true
    elif [ "$TUI_BACKEND" = "whiptail" ]; then
        whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --msgbox "$message" "$height" "$width" 2>/dev/null || true
    else
        echo ""
        echo "=== $title ==="
        echo "$message"
        echo ""
        read -rp "Press Enter to continue..."
    fi
}

tui_input() {
    local title="$1"
    local label="$2"
    local default_value="$3"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        local result="${AGENT_INPUT_VALUE:-}"
        [ -z "$result" ] && result="$default_value"
        agent_output "input" "$title" "$result"
        echo "$result"
        return 0
    fi

    local size
    size=$(_tui_get_size)
    local height
    height=$(echo "$size" | cut -d' ' -f1)
    local width
    width=$(echo "$size" | cut -d' ' -f2)
    local tmpfile
    tmpfile=$(_tui_mktemp)
    trap '_tui_cleanup '"'$tmpfile'"'' EXIT

    if [ "$TUI_BACKEND" = "dialog" ]; then
        if dialog --colors --backtitle "$TUI_BACKTITLE" --title "$title" --inputbox "\Z3$label\Zn" "$height" "$width" "$default_value" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            trap - ERR
            echo "$result"
            return 0
        else
            rm -f "$tmpfile"
            trap - ERR
            return 1
        fi
    elif [ "$TUI_BACKEND" = "whiptail" ]; then
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --inputbox "$label" "$height" "$width" "$default_value" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            trap - ERR
            echo "$result"
            return 0
        else
            rm -f "$tmpfile"
            trap - ERR
            return 1
        fi
    else
        trap - ERR
        echo ""
        echo "=== $title ==="
        local result
        read -rp "$label [$default_value]: " result
        [ -z "$result" ] && result="$default_value"
        echo "$result"
        return 0
    fi
}

tui_password() {
    local title="$1"
    local label="$2"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        local result="${AGENT_PASSWORD_VALUE:-}"
        agent_output "password" "$title" "***"
        echo "$result"
        return 0
    fi

    local size
    size=$(_tui_get_size)
    local height
    height=$(echo "$size" | cut -d' ' -f1)
    local width
    width=$(echo "$size" | cut -d' ' -f2)
    local tmpfile
    tmpfile=$(_tui_mktemp)
    trap '_tui_cleanup '"'$tmpfile'"'' EXIT

    if [ "$TUI_BACKEND" = "dialog" ]; then
        if dialog --colors --backtitle "$TUI_BACKTITLE" --title "$title" --passwordbox "\Z3$label\Zn" "$height" "$width" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            trap - ERR
            echo "$result"
            return 0
        else
            rm -f "$tmpfile"
            trap - ERR
            return 1
        fi
    elif [ "$TUI_BACKEND" = "whiptail" ]; then
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --passwordbox "$label" "$height" "$width" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            trap - ERR
            echo "$result"
            return 0
        else
            rm -f "$tmpfile"
            trap - ERR
            return 1
        fi
    else
        trap - ERR
        echo ""
        echo "=== $title ==="
        local result
        read -rsp "$label: " result
        echo "" >&2
        echo "$result"
        return 0
    fi
}

tui_progress() {
    local title="$1"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            agent_output "progress" "$title" "$line"
        done
        return 0
    fi

    local size
    size=$(_tui_get_size)
    local height
    height=$(echo "$size" | cut -d' ' -f1)
    local width
    width=$(echo "$size" | cut -d' ' -f2)

    if [ "$TUI_BACKEND" = "dialog" ] && [ "$TUI_HAS_GAUGE" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            local percent
            percent=$(echo "$line" | cut -d' ' -f1)
            local message
            message=$(echo "$line" | cut -d' ' -f2-)
            echo "$percent" | dialog --colors --backtitle "$TUI_BACKTITLE" --title "$title" --gauge "\Z3$message\Zn" "$height" "$width" 2>/dev/null || break
        done
    else
        local line
        while IFS= read -r line; do
            local percent
            percent=$(echo "$line" | cut -d' ' -f1)
            local message
            message=$(echo "$line" | cut -d' ' -f2-)
            echo "[$percent%] $message"
        done
    fi
}

tui_tailbox() {
    local title="$1"
    local filepath="$2"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        agent_output "tailbox" "$title" "$filepath"
        return 0
    fi

    local size
    size=$(_tui_get_size)
    local height
    height=$(echo "$size" | cut -d' ' -f1)
    local width
    width=$(echo "$size" | cut -d' ' -f2)

    if [ "$TUI_BACKEND" = "dialog" ] && [ "$TUI_HAS_TAILBOX" -eq 1 ]; then
        dialog --colors --backtitle "$TUI_BACKTITLE" --title "$title" --tailbox "$filepath" "$height" "$width" 2>/dev/null || true
    else
        echo "=== $title === (refreshing every 1 second, press 'q' to exit)"
        less +F "$filepath" 2>/dev/null || tail -f "$filepath"
    fi
}

tui_checklist() {
    local title="$1"
    local description="$2"
    shift 2
    local size
    size=$(_tui_get_size)
    local height
    height=$(echo "$size" | cut -d' ' -f1)
    local width
    width=$(echo "$size" | cut -d' ' -f2)
    local tmpfile
    tmpfile=$(_tui_mktemp)
    trap '_tui_cleanup '"'$tmpfile'"'' EXIT

    if [ "$TUI_BACKEND" = "dialog" ]; then
        local items=()
        while [ $# -ge 3 ]; do
            local state="$3"
            [ "$state" = "ON" ] && state="on" || state="off"
            items+=("$2" "$1" "$state")
            shift 3
        done
        if dialog --colors --backtitle "$TUI_BACKTITLE" --title "$title" --checklist "\Z3$description\Zn" "$height" "$width" 10 "${items[@]}" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            trap - ERR
            echo "$result"
            return 0
        else
            rm -f "$tmpfile"
            trap - ERR
            return 1
        fi
    elif [ "$TUI_BACKEND" = "whiptail" ]; then
        local items=()
        while [ $# -ge 3 ]; do
            items+=("$2" "$1" "$3")
            shift 3
        done
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --checklist "$description" "$height" "$width" 10 "${items[@]}" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            trap - ERR
            echo "$result"
            return 0
        else
            rm -f "$tmpfile"
            trap - ERR
            return 1
        fi
    else
        trap - ERR
        echo ""
        echo "=== $title ==="
        echo "$description"
        echo ""
        local idx=1
        local tags=()
        local states=()
        while [ $# -ge 3 ]; do
            echo "  $idx) [$3] $1"
            tags+=("$2")
            states+=("$3")
            shift 3
            idx=$((idx + 1))
        done
        echo ""
        echo "Enter numbers to toggle (comma-separated), empty to finish:"
        local choices
        read -rp "> " choices
        local result=""
        if [ -n "$choices" ]; then
            local choice
            for choice in $(echo "$choices" | tr ',' ' '); do
                if [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ] 2>/dev/null; then
                    [ -n "$result" ] && result="$result "
                    result="$result${tags[$((choice - 1))]}"
                fi
            done
        fi
        echo "$result"
        return 0
    fi
}
