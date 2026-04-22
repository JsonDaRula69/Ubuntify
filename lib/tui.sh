#!/bin/bash
#
# lib/tui.sh - Text User Interface (TUI) module for deployment scripts
#
# Provides menu primitives that work with whiptail or raw bash read.
# Auto-detects available backend at source time.
#

[ "${_TUI_SH_SOURCED:-0}" -eq 1 ] && return 0
_TUI_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"

readonly TUI_BACKTITLE="Ubuntify - Mac Pro Conversion Tool v${APP_VERSION:-dev}"

## Backend Detection

# TUI_BACKEND is initially set at source time but NOT readonly.
# check_tui_prerequisites() locks it after detecting available backend.

_tui_detect_backend() {
    if command -v whiptail >/dev/null 2>&1; then
        TUI_BACKEND="whiptail"
    else
        TUI_BACKEND="raw"
    fi
}

TUI_BACKEND_LOCKED=0
_tui_detect_backend

## Prerequisites Check

check_tui_prerequisites() {
    if [ "$TUI_BACKEND_LOCKED" -eq 1 ]; then
        return 0
    fi

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        if [ "$TUI_BACKEND" = "raw" ]; then
            log_warn "No whiptail available — falling back to raw TUI (limited UX)"
        fi
        TUI_BACKEND_LOCKED=1
        readonly TUI_BACKEND TUI_BACKEND_LOCKED
        return 0
    fi

    if [ "$TUI_BACKEND" != "whiptail" ]; then
        echo "" >&2
        echo "  ${YELLOW} No whiptail available — raw text fallback (limited menus, no progress bars).${NC}" >&2
        echo "" >&2
        echo "  Install whiptail via Homebrew for a better TUI experience: brew install newt${NC}" >&2
    fi

    TUI_BACKEND_LOCKED=1
    readonly TUI_BACKEND TUI_BACKEND_LOCKED
    return 0
}

## Dependency Installation

check_dependencies() {
    local missing_cmds=""
    local missing_brews=""
    local core_cmds="xorriso sgdisk comm python3"

    for cmd in $core_cmds; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds="${missing_cmds}${missing_cmds:+ }$cmd"
            case "$cmd" in
                xorriso) missing_brews="${missing_brews}${missing_brews:+ }xorriso" ;;
                sgdisk) missing_brews="${missing_brews}${missing_brews:+ }gptfdisk" ;;
                comm) missing_brews="${missing_brews}${missing_brews:+ }coreutils" ;;
                python3) missing_brews="${missing_brews}${missing_brews:+ }python3" ;;
            esac
        fi
    done

    if [ -z "$missing_cmds" ]; then
        return 0
    fi

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        log_warn "Missing required commands: $missing_cmds"
        log_warn "Install with: brew install $missing_brews"
        if [ "${DRY_RUN:-0}" -eq 1 ]; then
            log_info "[DRY-RUN] Would install: brew install $missing_brews"
            return 0
        fi
        die "Missing required commands: $missing_cmds. Install with: brew install $missing_brews"
    fi

    if command -v brew >/dev/null 2>&1; then
        printf '  Missing required commands: %s\n' "$missing_cmds" >&2
        printf '  Install via Homebrew? (yes/no): ' >&2
        local response
        IFS= read -r response < /dev/tty
        case "$response" in
            yes|y|Y)
                if [ "${DRY_RUN:-0}" -eq 1 ]; then
                    echo "  ${YELLOW}[DRY-RUN]${NC} Would run: brew install $missing_brews" >&2
                else
                    echo "  Installing dependencies via Homebrew: $missing_brews..." >&2
                    if brew install $missing_brews 2>&1; then
                        echo "  ${GREEN}Dependencies installed successfully.${NC}" >&2
                    else
                        die "Failed to install dependencies. Install manually: brew install $missing_brews"
                    fi
                fi
                ;;
            *)
                die "Missing required commands: $missing_cmds. Install with: brew install $missing_brews"
                ;;
        esac
    else
        die "Missing required commands: $missing_cmds. Install Homebrew first: https://brew.sh, then: brew install $missing_brews"
    fi

    for cmd in $core_cmds; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "Required command $cmd still not found after installation. Aborting."
        fi
    done
}

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

# Global result variable — used by tui_menu, tui_input, tui_password, tui_checklist
# to pass results back to callers without using $() subshells (which break whiptail).
_TUI_RESULT=""

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
            _TUI_RESULT="$selection"
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

    if [ "$TUI_BACKEND" = "whiptail" ]; then
        local items=()
        while [ $# -ge 2 ]; do
            items+=("$2" "$1" "OFF")
            shift 2
        done
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --radiolist "$description" "$height" "$width" 10 "${items[@]}" 2>"$tmpfile"; then
            _TUI_RESULT=$(cat "$tmpfile")
            rm -f "$tmpfile"
            return 0
        else
            rm -f "$tmpfile"
            return 1
        fi
    else
        local labels=()
        local tags=()
        local count=0
        while [ $# -ge 2 ]; do
            labels+=("$1")
            tags+=("$2")
            shift 2
            count=$((count + 1))
        done

        # No TTY — numbered fallback
        if ! [ -t 0 ] 2>/dev/null || ! [ -t 1 ] 2>/dev/null; then
            printf '\n' >&2
            printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 66))" >&2
            printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((62 - ${#title})) '' >&2
            printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 66))" >&2
            [ -n "$description" ] && printf '    ║  %b%s%b%*s║\n' "$CYAN" "$description" "$NC" $((62 - ${#description})) '' >&2
            [ -n "$description" ] && printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 66))" >&2
            local n=1
            while [ $n -le $count ]; do
                printf '    ║  %d. %b%s%b%*s║\n' "$n" "$WHITE" "${labels[$((n-1))]}" "$NC" $((58 - ${#labels[$((n-1))]})) '' >&2
                n=$((n + 1))
            done
            printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 66))" >&2
            printf '\n' >&2
            local response
            while true; do
                printf '    %bEnter choice [1-%d]:%b ' "$BRIGHT_CYAN" "$count" "$NC" >&2
                IFS= read -r response < /dev/tty || return 1
                case "$response" in
                    ''|*[!0-9]*) ;;
                    *)
                        if [ "$response" -ge 1 ] && [ "$response" -le "$count" ]; then
                            _TUI_RESULT="${tags[$((response-1))]}"
                            return 0
                        fi
                        ;;
                esac
            done
            return 1
        fi

        # Arrow-key interactive menu
        local selected=0
        local width=66
        while true; do
            clear 2>/dev/null || printf '\033[2J\033[H'
            printf '\n'
            printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
            printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) ''
            printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
            [ -n "$description" ] && printf '    ║  %b%s%b%*s║\n' "$CYAN" "$description" "$NC" $((width - ${#description} - 4)) ''
            [ -n "$description" ] && printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 "$width"))"
            local i=0
            while [ $i -lt $count ]; do
                if [ $i -eq $selected ]; then
                    printf '    ║  %b▸%b %b%s%b%*s║\n' "$BRIGHT_CYAN" "$NC" "$BRIGHT_CYAN" "${labels[$i]}" "$NC" $((width - ${#labels[$i]} - 6)) ''
                else
                    printf '    ║    %b%s%b%*s║\n' "$WHITE" "${labels[$i]}" "$NC" $((width - ${#labels[$i]} - 6)) ''
                fi
                i=$((i + 1))
            done
            printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))"
            printf '\n'
            printf '    %b↑↓ Navigate  │  ENTER Select  │  Q Back%b\n' "$DIM" "$NC"

            local key
            IFS= read -rsn1 key < /dev/tty
            case "$key" in
                $'\e')
                    IFS= read -rsn1 -t 0.1 key
                    [ -n "$key" ] && IFS= read -rsn1 -t 0.1 key
                    case "$key" in
                        A) selected=$((selected > 0 ? selected - 1 : count - 1)) ;;
                        B) selected=$((selected < count - 1 ? selected + 1 : 0)) ;;
                    esac
                    ;;
                '')
                    _TUI_RESULT="${tags[$selected]}"
                    return 0
                    ;;
                q|Q)
                    return 1
                    ;;
                [1-9])
                    local num=$((10#$key - 1))
                    if [ $num -lt $count ]; then
                        selected=$num
                    fi
                    ;;
            esac
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

    if [ "$TUI_BACKEND" = "whiptail" ]; then
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --yesno "$message" "$height" "$width" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        # No TTY — simple yes/no
        if ! [ -t 0 ] 2>/dev/null || ! [ -t 1 ] 2>/dev/null; then
            printf '\n' >&2
            printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 66))" >&2
            printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((62 - ${#title})) '' >&2
            printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 66))" >&2
            printf '    ║  %b%s%b%*s║\n' "$CYAN" "$message" "$NC" $((62 - ${#message})) '' >&2
            printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 66))" >&2
            printf '\n' >&2
            local response
            while true; do
                printf '    %bProceed? (yes/no):%b ' "$BRIGHT_CYAN" "$NC" >&2
                if ! IFS= read -r response < /dev/tty; then
                    printf '\n' >&2
                    return 1
                fi
                printf '\n' >&2
                case "$response" in
                    yes|y|Y) return 0 ;;
                    no|n|N) return 1 ;;
                esac
            done
            return 1
        fi

        # Arrow-key interactive confirm
        local selected=0
        local width=66
        while true; do
            clear 2>/dev/null || printf '\033[2J\033[H'
            printf '\n'
            printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
            printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) ''
            printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
            printf '    ║  %b%s%b%*s║\n' "$CYAN" "$message" "$NC" $((width - ${#message} - 4)) ''
            printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 "$width"))"

            if [ $selected -eq 0 ]; then
                printf '    ║  %b▸%b %bYes%b%*s║\n' "$BRIGHT_CYAN" "$NC" "$BRIGHT_CYAN" "$NC" $((width - 9)) ''
                printf '    ║    %bNo%b%*s║\n' "$WHITE" "$NC" $((width - 8)) ''
            else
                printf '    ║    %bYes%b%*s║\n' "$WHITE" "$NC" $((width - 9)) ''
                printf '    ║  %b▸%b %bNo%b%*s║\n' "$BRIGHT_CYAN" "$NC" "$BRIGHT_CYAN" "$NC" $((width - 8)) ''
            fi

            printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))"
            printf '\n'
            printf '    %b↑↓ Select  │  ENTER Confirm  │  Y/N Shortcut%b\n' "$DIM" "$NC"

            local key
            IFS= read -rsn1 key < /dev/tty
            case "$key" in
                $'\e')
                    IFS= read -rsn1 -t 0.1 key
                    [ -n "$key" ] && IFS= read -rsn1 -t 0.1 key
                    case "$key" in
                        A|D) selected=$((1 - selected)) ;;
                        B|C) selected=$((1 - selected)) ;;
                    esac
                    ;;
                '')
                    [ $selected -eq 0 ] && return 0 || return 1
                    ;;
                y|Y) return 0 ;;
                n|N) return 1 ;;
            esac
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

    if [ "$TUI_BACKEND" = "whiptail" ]; then
        whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --msgbox "$message" "$height" "$width" 2>/dev/null || true
    else
        local width=66
        printf '\n' >&2
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) '' >&2
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%*s║\n' "$CYAN" "$message" "$NC" $((width - ${#message} - 4)) '' >&2
        printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))" >&2
        printf '\n' >&2
        printf '    %bPress ENTER to continue...%b' "$DIM" "$NC" >&2
        IFS= read -r < /dev/tty
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
        _TUI_RESULT="$result"
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

    if [ "$TUI_BACKEND" = "whiptail" ]; then
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --inputbox "$label" "$height" "$width" "$default_value" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            _TUI_RESULT="$result"
            return 0
        else
            rm -f "$tmpfile"
            return 1
        fi
    else
        local width=66
        local display_default="${default_value:-}"
        [ -n "$display_default" ] && display_default=" [$display_default]"
        printf '\n' >&2
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) '' >&2
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%s%*s║\n' "$CYAN" "$label" "$NC" "$display_default" $((width - ${#label} - ${#display_default} - 4)) '' >&2
        printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))" >&2
        printf '\n' >&2
        printf '    %b▸%b ' "$BRIGHT_CYAN" "$NC" >&2
        local result
        if [ -t 0 ]; then
            IFS= read -r result
        else
            IFS= read -r result < /dev/tty
        fi
        [ -z "$result" ] && result="$default_value"
        _TUI_RESULT="$result"
        return 0
    fi
}

tui_password() {
    local title="$1"
    local label="$2"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        local result="${AGENT_PASSWORD_VALUE:-}"
        agent_output "password" "$title" "***"
        _TUI_RESULT="$result"
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

    if [ "$TUI_BACKEND" = "whiptail" ]; then
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --passwordbox "$label" "$height" "$width" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            _TUI_RESULT="$result"
            return 0
        else
            rm -f "$tmpfile"
            return 1
        fi
    else
        local width=66
        local show_pass=0
        printf '\n' >&2
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) '' >&2
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%*s║\n' "$CYAN" "$label" "$NC" $((width - ${#label} - 4)) '' >&2
        printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))" >&2
        printf '    %b▸%b ' "$BRIGHT_CYAN" "$NC" >&2
        local pass=""
        local char
        local mask_stars=""
        # Read one char at a time; show * per char; Ctrl+S toggles visibility
        while IFS= read -r -n1 -s char; do
            if [ -z "$char" ]; then
                # Enter key (empty read with -n1)
                break
            elif [ "$char" = $'\003' ] || [ "$char" = $'\033' ]; then
                # Ctrl-C or Esc — cancel
                printf '\n' >&2
                _TUI_RESULT=""
                return 1
            elif [ "$char" = $'\023' ]; then
                # Ctrl+S — toggle show/hide
                show_pass=$((1 - show_pass))
                # Redraw: erase current display, reprint with new mask
                local display_len=${#pass}
                printf "\r%*s\r" $((display_len + 4)) '' >&2
                if [ "$show_pass" -eq 1 ]; then
                    printf '    %b▸%b %s' "$BRIGHT_CYAN" "$NC" "$pass" >&2
                else
                    printf '    %b▸%b %s' "$BRIGHT_CYAN" "$NC" "$mask_stars" >&2
                fi
            elif [ "$char" = $'\177' ] || [ "$char" = $'\010' ]; then
                # Backspace / Delete
                if [ -n "$pass" ]; then
                    pass="${pass%?}"
                    mask_stars="${mask_stars%?}"
                    printf '\b \b' >&2
                fi
            else
                pass="${pass}${char}"
                mask_stars="${mask_stars}*"
                if [ "$show_pass" -eq 1 ]; then
                    printf '%s' "$char" >&2
                else
                    printf '*' >&2
                fi
            fi
        done < /dev/tty
        printf '\n\n    %b(Ctrl+S toggles password visibility)%b\n' "$DIM" "$NC" >&2
        printf '\n' >&2
        _TUI_RESULT="$pass"
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

    local line
    while IFS= read -r line; do
        local percent
        percent=$(echo "$line" | cut -d' ' -f1)
        local message
        message=$(echo "$line" | cut -d' ' -f2-)
        printf '    %b[%3s%%]%b %b%s%b\n' "$BRIGHT_PHOSPHOR" "$percent" "$NC" "$WHITE" "$message" "$NC"
    done
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

    local width=66
    printf '\n' >&2
    printf '    %b╔%s╗%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 "$width"))" "$NC" >&2
    printf '    %b║%b  %b%s%b%*s%b║%b\n' "$PHOSPHOR" "$NC" "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) '' "$PHOSPHOR" "$NC" >&2
    printf '    %b╚%s╝%b\n' "$PHOSPHOR" "$(printf '─%.0s' $(seq 1 "$width"))" "$NC" >&2
    printf '    %b(refreshing, press q to exit)%b\n' "$DIM" "$NC" >&2
    less +F "$filepath" 2>/dev/null || tail -f "$filepath"
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

    if [ "$TUI_BACKEND" = "whiptail" ]; then
        local items=()
        while [ $# -ge 3 ]; do
            items+=("$2" "$1" "$3")
            shift 3
        done
        if whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --checklist "$description" "$height" "$width" 10 "${items[@]}" 2>"$tmpfile"; then
            local result
            result=$(cat "$tmpfile")
            rm -f "$tmpfile"
            _TUI_RESULT="$result"
            return 0
        else
            rm -f "$tmpfile"
            return 1
        fi
    else
        local labels=()
        local tags=()
        local states=()
        while [ $# -ge 3 ]; do
            labels+=("$1")
            tags+=("$2")
            states+=("$3")
            shift 3
        done
        local count=${#labels[@]}
        local selected=0
        local choices=()
        local i
        for i in $(seq 0 $((count - 1))); do
            if [ "${states[$i]}" = "ON" ]; then
                choices+=(1)
            else
                choices+=(0)
            fi
        done

        # No TTY — numbered fallback
        if ! [ -t 0 ] 2>/dev/null || ! [ -t 1 ] 2>/dev/null; then
            printf '\n' >&2
            printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 66))" >&2
            printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((62 - ${#title})) '' >&2
            printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 66))" >&2
            [ -n "$description" ] && printf '    ║  %b%s%b%*s║\n' "$CYAN" "$description" "$NC" $((62 - ${#description})) '' >&2
            [ -n "$description" ] && printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 66))" >&2
            local idx=1
            while [ $idx -le $count ]; do
                local mark=" "
                [ "${choices[$((idx-1))]}" -eq 1 ] && mark="*"
                printf '    ║  [%s] %d. %b%s%b%*s║\n' "$mark" "$idx" "$WHITE" "${labels[$((idx-1))]}" "$NC" $((54 - ${#labels[$((idx-1))]})) '' >&2
                idx=$((idx + 1))
            done
            printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 66))" >&2
            printf '\n' >&2
            printf '    %bEnter numbers to toggle (comma-separated), empty to finish:%b ' "$BRIGHT_CYAN" "$NC" >&2
            local choices_input
            IFS= read -r choices_input < /dev/tty || return 1
            local result=""
            if [ -n "$choices_input" ]; then
                local choice
                for choice in $(echo "$choices_input" | tr ',' ' '); do
                    if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ] 2>/dev/null; then
                        choices[$((choice - 1))]=$((1 - ${choices[$((choice - 1))]}))
                    fi
                done
            fi
            for i in $(seq 0 $((count - 1))); do
                if [ "${choices[$i]}" -eq 1 ]; then
                    [ -n "$result" ] && result="$result "
                    result="$result${tags[$i]}"
                fi
            done
            _TUI_RESULT="$result"
            return 0
        fi

        # Arrow-key interactive checklist
        local width=66
        while true; do
            clear 2>/dev/null || printf '\033[2J\033[H'
            printf '\n'
            printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
            printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) ''
            printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
            [ -n "$description" ] && printf '    ║  %b%s%b%*s║\n' "$CYAN" "$description" "$NC" $((width - ${#description} - 4)) ''
            [ -n "$description" ] && printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 "$width"))"
            i=0
            while [ $i -lt $count ]; do
                local marker="  "
                local checkbox="[ ]"
                if [ $i -eq $selected ]; then
                    marker=" $BRIGHT_CYAN▸$NC"
                fi
                if [ "${choices[$i]}" -eq 1 ]; then
                    checkbox="[$BRIGHT_PHOSPHOR█$NC]"
                fi
                if [ $i -eq $selected ]; then
                    printf '    ║%s %b%s%b  %b%s%b%*s║\n' "$marker" "$BOLD" "$checkbox" "$NC" "$BRIGHT_CYAN" "${labels[$i]}" "$NC" $((width - ${#labels[$i]} - 12)) ''
                else
                    printf '    ║%s %s  %b%s%b%*s║\n' "$marker" "$checkbox" "$WHITE" "${labels[$i]}" "$NC" $((width - ${#labels[$i]} - 12)) ''
                fi
                i=$((i + 1))
            done
            printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))"

            local selected_tags=""
            local sel_count=0
            i=0
            while [ $i -lt $count ]; do
                if [ "${choices[$i]}" -eq 1 ]; then
                    [ -n "$selected_tags" ] && selected_tags="$selected_tags "
                    selected_tags="$selected_tags${tags[$i]}"
                    sel_count=$((sel_count + 1))
                fi
                i=$((i + 1))
            done
            printf '\n'
            if [ $sel_count -gt 0 ]; then
                printf '    %b▸ Selected: %d item(s)%b\n' "$BRIGHT_PHOSPHOR" "$sel_count" "$NC"
            else
                printf '    %b▸ No items selected%b\n' "$DIM" "$NC"
            fi
            printf '\n'
            printf '    %b↑↓ Navigate  │  SPACE Toggle  │  ENTER Done  │  Q Cancel%b\n' "$DIM" "$NC"

            local key
            IFS= read -rsn1 key < /dev/tty
            case "$key" in
                $'\e')
                    IFS= read -rsn1 -t 0.1 key
                    [ -n "$key" ] && IFS= read -rsn1 -t 0.1 key
                    case "$key" in
                        A) selected=$((selected > 0 ? selected - 1 : count - 1)) ;;
                        B) selected=$((selected < count - 1 ? selected + 1 : 0)) ;;
                    esac
                    ;;
                ' ')
                    choices[$selected]=$((1 - ${choices[$selected]}))
                    ;;
                '')
                    _TUI_RESULT="$selected_tags"
                    return 0
                    ;;
                q|Q)
                    return 1
                    ;;
                [1-9])
                    local num=$((10#$key - 1))
                    if [ $num -lt $count ]; then
                        selected=$num
                    fi
                    ;;
            esac
        done
    fi
}

## ASCII Art TUI Functions (raw backend enhancements)

tui_cool_header() {
    local subtitle="${1:-Mac Pro Conversion and Management Tool}"
    local art=" /\$\$   /\$\$ /\$\$                             /\$\$     /\$\$  /\$\$\$\$\$\$          |
| \$\$  | \$\$| \$\$                            | \$\$    |__/ /\$\$__  \$\$         |
| \$\$  | \$\$| \$\$\$\$\$\$\$  /\$\$   /\$\$ /\$\$\$\$\$\$\$  /\$\$\$\$\$\$\$   /\$\$| \$\$  \\\\__//\$\$   /\$\$|
| \$\$  | \$\$| \$\$__  \$\$| \$\$  | \$\$| \$\$__  \$\$|_  \$\$_/  | \$\$| \$\$\$\$   | \$\$  | \$\$|
| \$\$  | \$\$| \$\$  \\ \$\$| \$\$  | \$\$| \$\$  \\ \$\$  | \$\$    | \$\$| \$\$_/   | \$\$  | \$\$|
| \$\$  | \$\$| \$\$  | \$\$| \$\$  | \$\$| \$\$  | \$\$  | \$\$ /\$\$| \$\$| \$\$     | \$\$  | \$\$|
|  \$\$\$\$\$\$/| \$\$\$\$\$\$\$/|  \$\$\$\$\$\$/| \$\$  | \$\$  |  \$\$\$\$/| \$\$| \$\$     |  \$\$\$\$\$\$\$|
 \\______/ |_______/  \\______/ |__/  |__/   \\___/  |__/|__/      \\____  \$\$|
                                                                /\$\$  | \$\$|
                                                               |  \$\$\$\$\$\$/|
                                                                \\______/ |"
    local max_width=0 line
    while IFS= read -r line; do
        [ "${#line}" -gt "$max_width" ] && max_width=${#line}
    done <<< "$art"
    local sub_len=${#subtitle}
    [ "$sub_len" -gt "$max_width" ] && max_width=$sub_len
    local bar
    bar=$(printf '%*s' $max_width '' | tr ' ' '─')
    echo ""
    printf '  %b┌─%s─┐%b\n' "$PHOSPHOR" "$bar" "$NC"
    while IFS= read -r line; do
        printf "  %b│%b %b%s%b%b%*s│%b\n" "$PHOSPHOR" "$NC" "$BRIGHT_PHOSPHOR" "$line" "$NC" "$PHOSPHOR" $((max_width - ${#line})) '' "$NC"
    done <<< "$art"
    printf "  %b│%b %b%s%b%b%*s│%b\n" "$PHOSPHOR" "$NC" "$BRIGHT_PHOSPHOR" "$subtitle" "$NC" "$PHOSPHOR" $((max_width - sub_len)) '' "$NC"
    printf '  %b└─%s─┘%b\n' "$PHOSPHOR" "$bar" "$NC"
    echo ""
}

tui_ascii_header() {
    tui_cool_header "$1"
}

tui_box() {
    local title="$1"
    local content="$2"
    local width="${3:-76}"
    printf '\n'
    printf '    %b╗%s╗%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 "$width"))" "$NC"
    printf '    %b║%b %b%s%b%*s %b║%b\n' "$PHOSPHOR" "$NC" "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 1)) '' "$PHOSPHOR" "$NC"
    printf '    %b╠%s╣%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 "$width"))" "$NC"
    printf '%s' "$content" | while IFS= read -r line; do
        printf '    %b║%b %s%*s %b║%b\n' "$PHOSPHOR" "$NC" "$line" $((width - ${#line} - 1)) '' "$PHOSPHOR" "$NC"
    done
    printf '    %b╚%s╝%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 "$width"))" "$NC"
}

tui_section() {
    local title="$1"
    local width="${2:-76}"
    printf '\n'
    printf '    %b╔%s╗%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 "$width"))" "$NC"
    printf '    %b║%b  %b%s%b %*s%b║%b\n' "$PHOSPHOR" "$NC" "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 3)) '' "$PHOSPHOR" "$NC"
    printf '    %b╚%s╝%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 "$width"))" "$NC"
}

tui_checklist_box() {
    local title="$1"
    local description="$2"
    shift 2
    local size
    size=$(_tui_get_size)
    local width
    width=$(echo "$size" | cut -d' ' -f2)

    if [ "$TUI_BACKEND" = "whiptail" ]; then
        tui_checklist "$title" "$description" "$@"
        return $?
    fi

    local idx=1
    local tags=()
    local states=()
    local labels=()
    printf '\n'
    printf '    %b╔%s╗%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 $((width - 4))))" "$NC"
    printf '    %b║%b  %b%s%b%*s%b║%b\n' "$PHOSPHOR" "$NC" "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 5)) '' "$PHOSPHOR" "$NC"
    printf '    %b╠%s╣%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 $((width - 4))))" "$NC"
    [ -n "$description" ] && printf '    %b║%b  %b%s%b%*s%b║%b\n' "$PHOSPHOR" "$NC" "$DIM" "$description" "$NC" $((width - ${#description} - 5)) '' "$PHOSPHOR" "$NC"
    [ -n "$description" ] && printf '    %b╟%s╢%b\n' "$PHOSPHOR" "$(printf '─%.0s' $(seq 1 $((width - 4))))" "$NC"
    while [ $# -ge 2 ]; do
        local label="$1"
        local tag="$2"
        labels+=("$label")
        tags+=("$tag")
        local state="[ ]"
        printf '    %b║%b    %s  %d. %b%s%b%*s%b║%b\n' "$PHOSPHOR" "$NC" "$state" "$idx" "$WHITE" "$label" "$NC" $((width - ${#label} - 13)) '' "$PHOSPHOR" "$NC"
        shift 2
        idx=$((idx + 1))
    done
    printf '    %b╚%s╝%b\n' "$PHOSPHOR" "$(printf '─%.0s' $(seq 1 $((width - 4))))" "$NC"
    printf '\n'
    printf '    %b↑↓ Navigate  │  SPACE Toggle  │  ENTER Confirm  │  Q Quit%b\n' "$DIM" "$NC"
    printf '\n'
    printf '    > '
    return 0
}

tui_checkbox() {
    local title="$1"
    local description="${2:-}"
    shift 2
    local options=()
    local tags=()
    local width=70

    while [ $# -ge 2 ]; do
        options+=("$1")
        tags+=("$2")
        shift 2
    done
    local count=${#options[@]}
    local selected=0
    local choices=()
    local i
    for i in $(seq 0 $((count - 1))); do
        choices+=(0)
    done

    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        printf '\n'
        printf '    %b╔%s╗%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 $((width))))" "$NC"
        printf '    %b║%b  %b%s%b%*s%b║%b\n' "$PHOSPHOR" "$NC" "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) '' "$PHOSPHOR" "$NC"
        printf '    %b╠%s╣%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 "$width"))" "$NC"
        [ -n "$description" ] && printf '    %b║%b  %b%s%b\n' "$PHOSPHOR" "$NC" "$DIM" "$description" "$NC"
        [ -n "$description" ] && printf '    %b╟%s╢%b\n' "$PHOSPHOR" "$(printf '─%.0s' $(seq 1 "$width"))" "$NC"
        local i=0
        for option in "${options[@]}"; do
            local marker="  "
            local checkbox="[ ]"
            if [ $i -eq $selected ]; then
                marker=" $BRIGHT_CYAN▸$NC"
            fi
            if [ "${choices[$i]}" -eq 1 ]; then
                checkbox="[$BRIGHT_PHOSPHOR█$NC]"
            fi
            if [ $i -eq $selected ]; then
                printf '    %b║%b%s %b%s%b %s %s%*s%b║%b\n' "$PHOSPHOR" "$NC" "$marker" "$BOLD" "$checkbox" "$NC" "$((i + 1))." "$option" $((width - ${#option} - ${#checkbox} - ${#i} - 8)) '' "$PHOSPHOR" "$NC"
            else
                printf '    %b║%b%s %s %s %s%*s%b║%b\n' "$PHOSPHOR" "$NC" "$marker" "$checkbox" "$((i + 1))." "$option" $((width - ${#option} - ${#checkbox} - ${#i} - 8)) '' "$PHOSPHOR" "$NC"
            fi
            i=$((i + 1))
        done
        printf '    %b╚%s╝%b\n' "$PHOSPHOR" "$(printf '─%.0s' $(seq 1 "$width"))" "$NC"
        printf '\n'
        local selected_tags=""
        local sel_count=0
        i=0
        for tag in "${tags[@]}"; do
            if [ "${choices[$i]}" -eq 1 ]; then
                [ -n "$selected_tags" ] && selected_tags="$selected_tags, "
                selected_tags="$selected_tags$tag"
                sel_count=$((sel_count + 1))
            fi
            i=$((i + 1))
        done
        if [ $sel_count -gt 0 ]; then
            printf '    %b▸ Selected: %d item(s)%b\n' "$BRIGHT_PHOSPHOR" "$sel_count" "$NC"
        else
            printf '    %b▸ No items selected%b\n' "$DIM" "$NC"
        fi
        printf '\n'
        printf '    %b↑↓ Navigate  │  SPACE Toggle  │  ENTER Done  │  Q Cancel%b\n' "$DIM" "$NC"

        local key
        IFS= read -rsn1 key < /dev/tty
        case "$key" in
            $'\e')
                IFS= read -rsn1 -t 0.1 key
                [ -n "$key" ] && IFS= read -rsn1 -t 0.1 key
                case "$key" in
                    A) selected=$((selected > 0 ? selected - 1 : count - 1)) ;;
                    B) selected=$((selected < count - 1 ? selected + 1 : 0)) ;;
                esac
                ;;
            ' ')
                choices[$selected]=$((1 - ${choices[$selected]}))
                ;;
            '')
                _TUI_RESULT="$selected_tags"
                return 0
                ;;
            q|Q)
                return 1
                ;;
            [1-9])
                local num=$((10#$key - 1))
                if [ $num -lt $count ]; then
                    selected=$num
                fi
                ;;
        esac
    done
}

tui_grid_checklist() {
    local title="$1"
    shift
    local col1_width=30
    local col2_width=30
    local total_width=$((col1_width + col2_width + 20))

    if [ "$TUI_BACKEND" = "whiptail" ]; then
        return 0
    fi

    printf '\n'
    printf '    %b╔%s╗%b\n' "$PHOSPHOR" "$(printf '═%.0s' $(seq 1 $((total_width - 4))))" "$NC"
    printf '    %b║%b  %b%s%b%*s%b║%b\n' "$PHOSPHOR" "$NC" "$BOLD_WHITE" "$title" "$NC" $((total_width - ${#title} - 5)) '' "$PHOSPHOR" "$NC"
    printf '    %b╟%s╢%b\n' "$PHOSPHOR" "$(printf '─%.0s' $(seq 1 $((total_width - 4))))" "$NC"

    local idx=1
    _TUI_GRID_TAGS=""
    while [ $# -ge 2 ]; do
        local left_label="$1"
        local left_tag="$2"
        shift 2
        _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${left_tag}"
        local right_label=""
        local right_tag=""
        if [ $# -ge 2 ]; then
            right_label="$1"
            right_tag="$2"
            shift 2
            _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${right_tag}"
        fi

        printf '    %b║%b  [ ] %d. %s' "$PHOSPHOR" "$NC" "$idx" "$left_label"
        local pad=$((col1_width - ${#left_label} - ${#idx}))
        [ $pad -gt 0 ] && printf '%*s' "$pad" ''
        printf '      '
        if [ -n "$right_label" ]; then
            idx=$((idx + 1))
            printf '[ ] %d. %s' "$idx" "$right_label"
            pad=$((col2_width - ${#right_label} - ${#idx}))
            [ $pad -gt 0 ] && printf '%*s' "$pad" ''
        fi
        printf '  %b║%b\n' "$PHOSPHOR" "$NC"
    done

    printf '    %b╚%s╝%b\n' "$PHOSPHOR" "$(printf '─%.0s' $(seq 1 $((total_width - 4))))" "$NC"
    printf '\n'
    printf '    %bSPACE Toggle  │  ENTER Execute%b\n' "$DIM" "$NC"
}
