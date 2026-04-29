#!/bin/bash
#
# lib/tui.sh - Text User Interface (TUI) module for deployment scripts
#
# Provides menu primitives using raw bash read and terminal escape sequences.
#

[ "${_TUI_SH_SOURCED:-0}" -eq 1 ] && return 0
_TUI_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"

readonly TUI_BACKTITLE="Ubuntify - Mac Pro Conversion Tool v${APP_VERSION:-dev}"

# TUI module - raw backend only

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

# Set default terminal dimensions (95x30) but allow user override via TUI_COLS/TUI_LINES env vars.
# Only resizes macOS Terminal.app — other terminals are left as-is.
_tui_set_default_terminal_size() {
    [ "${AGENT_MODE:-0}" -eq 1 ] && return 0
    local default_cols="${TUI_COLS:-95}"
    local default_lines="${TUI_LINES:-30}"
    if [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ]; then
        osascript -e "tell application \"Terminal\"" \
            -e "    set custom title of front window to \"Ubuntify\"" \
            -e "    tell front window" \
            -e "        set number of columns to $default_cols" \
            -e "        set number of rows to $default_lines" \
            -e "    end tell" \
            -e "end tell" 2>/dev/null || true
    fi
}

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

_tui_box_message_lines() {
    local message="$1"
    local width="${2:-66}"
    local color="${3:-$CYAN}"
    local inner_width=$((width - 4))
    local expanded
    expanded=$(printf '%b' "$message")
    local IFS_OLD="$IFS"
    IFS=$'\n'
    local line
    for line in $expanded; do
        local display_line="$line"
        [ ${#display_line} -gt "$inner_width" ] && display_line="${display_line:0:$((inner_width - 1))}…"
        local pad=$((inner_width - ${#display_line}))
        printf '    ║  %b%s%b%*s║\n' "$color" "$display_line" "$NC" "$pad" ''
    done
    IFS="$IFS_OLD"
}

# Global result variable — used by tui_menu, tui_input, tui_password, tui_checklist
# to pass results back to callers without using $() subshells.
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
        if ! test -r /dev/tty 2>/dev/null || ! test -w /dev/tty 2>/dev/null; then
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
            {
                clear 2>/dev/null || printf '\033[2J\033[H]'
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
                printf '    %b↑↓ Navigate  │  ENTER Select  │  B Back  │  Ctrl+C Quit%b\n' "$DIM" "$NC"
            } >&2

            local key
            IFS= read -rsn1 key < /dev/tty
            case "$key" in
                $'\e')
                    IFS= read -rsn1 -t 1 key < /dev/tty
                    [ -n "$key" ] && IFS= read -rsn1 -t 1 key < /dev/tty
                    case "$key" in
                        A) selected=$((selected > 0 ? selected - 1 : count - 1)) ;;
                        B) selected=$((selected < count - 1 ? selected + 1 : 0)) ;;
                    esac
                    ;;
                ''|$'\r'|$'\n')
                    _TUI_RESULT="${tags[$selected]}"
                    return 0
                    ;;
                b|B)
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

    # No TTY — simple yes/no
        if ! test -r /dev/tty 2>/dev/null || ! test -w /dev/tty 2>/dev/null; then
            printf '\n' >&2
            printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 66))" >&2
            printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((62 - ${#title})) '' >&2
            printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 66))" >&2
            _tui_box_message_lines "$message" 66 "$CYAN" >&2
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
            {
                clear 2>/dev/null || printf '\033[2J\033[H]'
                printf '\n'
                printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
                printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) ''
                printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
                _tui_box_message_lines "$message" "$width" "$CYAN" >&2
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
            } >&2

            local key
            IFS= read -rsn1 key < /dev/tty
            case "$key" in
                $'\e')
                    IFS= read -rsn1 -t 1 key < /dev/tty
                    [ -n "$key" ] && IFS= read -rsn1 -t 1 key < /dev/tty
                    case "$key" in
                        A|D) selected=$((1 - selected)) ;;
                        B|C) selected=$((1 - selected)) ;;
                    esac
                    ;;
                ''|$'\r'|$'\n')
                    [ $selected -eq 0 ] && return 0 || return 1
                    ;;
                y|Y) return 0 ;;
                n|N) return 1 ;;
            esac
        done
}

tui_msgbox() {
    local title="$1"
    local message="$2"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        agent_output "msgbox" "$title" "$message"
        return 0
    fi

    local width=66
        printf '\n' >&2
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) '' >&2
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        _tui_box_message_lines "$message" "$width" "$CYAN" >&2
        printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))" >&2
        printf '\n' >&2
        printf '    %bPress ENTER to continue...%b' "$DIM" "$NC" >&2
        IFS= read -r < /dev/tty
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

    local width=66
        local show_pass=0
        printf '\n' >&2
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%*s║\n' "$BOLD_WHITE" "$title" "$NC" $((width - ${#title} - 4)) '' >&2
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))" >&2
        printf '    ║  %b%s%b%*s║\n' "$CYAN" "$label" "$NC" $((width - ${#label} - 4)) '' >&2
        printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))" >&2
        printf '    %b(Ctrl+S toggles visibility)%b\n' "$DIM" "$NC" >&2
        printf '    %b▸%b ' "$BRIGHT_CYAN" "$NC" >&2
        local pass=""
        local char
        local mask_stars=""
        # Disable terminal XON/XOFF flow control so Ctrl+S is passed through
        local _old_stty=""
        _old_stty=$(stty -g < /dev/tty 2>/dev/null) || true
        stty -ixon -ixoff < /dev/tty 2>/dev/null || true
        # Read one char at a time; show * per char; Ctrl+S toggles visibility
        while IFS= read -r -n1 -s char < /dev/tty; do
            if [ -z "$char" ] || [ "$char" = $'\r' ] || [ "$char" = $'\n' ]; then
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
        # Restore terminal flow control
        [ -n "$_old_stty" ] && stty "$_old_stty" < /dev/tty 2>/dev/null || true
        printf '\n' >&2
        _TUI_RESULT="$pass"
        return 0
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
        if ! test -r /dev/tty 2>/dev/null || ! test -w /dev/tty 2>/dev/null; then
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
            {
                clear 2>/dev/null || printf '\033[2J\033[H]'
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
                printf '    %b↑↓ Navigate  │  SPACE Toggle  │  ENTER Done  │  B Back  │  Ctrl+C Quit%b\n' "$DIM" "$NC"
            } >&2

            local key
            IFS= read -rsn1 key < /dev/tty
            case "$key" in
                $'\e')
                    IFS= read -rsn1 -t 1 key < /dev/tty
                    [ -n "$key" ] && IFS= read -rsn1 -t 1 key < /dev/tty
                    case "$key" in
                        A) selected=$((selected > 0 ? selected - 1 : count - 1)) ;;
                        B) selected=$((selected < count - 1 ? selected + 1 : 0)) ;;
                    esac
                    ;;
                ' ')
                    choices[$selected]=$((1 - ${choices[$selected]}))
                    ;;
                ''|$'\r'|$'\n')
                    _TUI_RESULT="$selected_tags"
                    return 0
                    ;;
                b|B)
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

## ASCII Art TUI Functions

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


tui_splash_init() {
    local subtitle="$1"
    shift

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        tui_cool_header "$subtitle"
        if [ $# -gt 0 ]; then
            local i=1
            local total=$#
            for step in "$@"; do
                local pct=$((i * 100 / total))
                agent_output "progress" "Initializing" "$step" "percent" "$pct"
                i=$((i + 1))
            done
        fi
        return 0
    fi

    clear 2>/dev/null || printf '\033[2J\033[H]'

    local art=" /\$\$   /\$\$ /\$\$                             /\$\$     /\$\$  /\$\$\$\$\$\$          |
| \$\$  | \$\$| \$\$                            | \$\$    |__/ /\$\$__  \$\$         |
| \$\$  | \$\$| \$\$\$\$\$\$\$  /\$\$   /\$\$ /\$\$\$\$\$\$\$  /\$\$\$\$\$\$\$   /\$\$| \$\$  \\\\__//\$\$   /\$\$|
| \$\$  | \$\$| \$\$__  \$\$| \$\$  | \$\$| \$\$__  \$\$|_  \$\$_/  | \$\$| \$\$\$\$   | \$\$  | \$\$|
| \$\$  | \$\$| \$\$  \\ \$\$| \$\$  | \$\$| \$\$  \\ \$\$  | \$\$ /\$\$| \$\$| \$\$_/   | \$\$  | \$\$|
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

    printf '\n'
    printf '  %b┌─%s─┐%b\n' "$PHOSPHOR" "$bar" "$NC"
    while IFS= read -r line; do
        printf "  %b│%b %b%s%b%b%*s│%b\n" "$PHOSPHOR" "$NC" "$BRIGHT_PHOSPHOR" "$line" "$NC" "$PHOSPHOR" $((max_width - ${#line})) '' "$NC"
    done <<< "$art"
    printf "  %b│%b %b%s%b%b%*s│%b\n" "$PHOSPHOR" "$NC" "$BRIGHT_PHOSPHOR" "$subtitle" "$NC" "$PHOSPHOR" $((max_width - sub_len)) '' "$NC"
    printf '  %b└─%s─┘%b\n' "$PHOSPHOR" "$bar" "$NC"
    printf '\n'
}

SPLASH_STEP_COUNT=0
SPLASH_STEP_CURRENT=0

tui_splash_step() {
    local label="$1"
    SPLASH_STEP_CURRENT=$((SPLASH_STEP_CURRENT + 1))
    local pct=$((SPLASH_STEP_CURRENT * 100 / SPLASH_STEP_COUNT))
    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        agent_output "progress" "$label" "$pct%%" "percent" "$pct"
        return 0
    fi
    printf '\r  %b[%3d%%]%b %b%s%b ... ' "$BRIGHT_PHOSPHOR" "$pct" "$NC" "$WHITE" "$label" "$NC"
}

tui_splash_step_done() {
    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        return 0
    fi
    printf '\r  %b[%3d%%]%b %b%s%b  %b✓%b\n' "$BRIGHT_PHOSPHOR" "$((SPLASH_STEP_CURRENT * 100 / SPLASH_STEP_COUNT))" "$NC" "$WHITE" "$1" "$NC" "$GREEN" "$NC"
}

tui_splash_fail() {
    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        agent_error "$1"
        return 0
    fi
    printf '\r  %b[%3d%%]%b %b%s%b  %b✗%b\n' "$BRIGHT_RED" "$((SPLASH_STEP_CURRENT * 100 / SPLASH_STEP_COUNT))" "$NC" "$WHITE" "$1" "$NC" "$RED" "$NC"
}

tui_splash_hold() {
    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        return 0
    fi
    printf '\n'
    printf '  %bPress ENTER to continue...%b' "$DIM" "$NC"
    IFS= read -r < /dev/tty
    printf '\n'
}









