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

readonly TUI_BACKTITLE="Ubuntify - Mac Pro Conversion Tool"

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
        echo "" >&2
        echo "=== $title ===" >&2
        echo -e "$description" >&2
        echo "" >&2
        local labels=""
        local tags=""
        local opt_num=1
        while [ $# -ge 2 ]; do
            local label="$1"
            local tag="$2"
            labels="${labels}|${opt_num}:${label}"
            tags="${tags}|${tag}"
            echo "  $opt_num) $label" >&2
            opt_num=$((opt_num + 1))
            shift 2
        done
        local max_opt=$((opt_num - 1))
        echo "" >&2
        local response
        while true; do
            read -rp "Enter choice [1-$max_opt]: " response < /dev/tty
            case "$response" in
                ''|*[!0-9]*) ;;
                *)
                    if [ "$response" -ge 1 ] && [ "$response" -le "$max_opt" ]; then
                        local IFS='|'
                        set -- $tags
                        local n=1
                        shift
                        for item in "$@"; do
                            if [ "$n" -eq "$response" ]; then
                                echo "$item"
                                return 0
                            fi
                            n=$((n + 1))
                        done
                    fi
                    ;;
            esac
            echo "Please enter a number between 1 and $max_opt." >&2
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
        echo "" >&2
        echo "=== $title ===" >&2
        echo -e "$message" >&2
        echo "" >&2
        local response
        while true; do
            read -rp "Proceed? (yes/no): " response < /dev/tty
            case "$response" in
                yes|y|Y) return 0 ;;
                no|n|N) return 1 ;;
            esac
            echo "Please enter 'yes' or 'no'." >&2
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
        echo "" >&2
        echo "=== $title ===" >&2
        echo -e "$message" >&2
        echo "" >&2
        read -rp "Press Enter to continue..." < /dev/tty
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
        echo "" >&2
        echo "=== $title ===" >&2
        printf '%s [%s]: ' "$label" "$default_value" >&2
        local result
        if [ -t 0 ]; then
            IFS= read -r result
        else
            IFS= read -r result < /dev/tty
        fi
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
        echo "" >&2
        echo "=== $title ===" >&2
        local tmpfile
        local pass
        tmpfile=$(_tui_mktemp)
        printf '%s: ' "$label" >&2
        if [ -t 0 ]; then
            IFS= read -rs pass
        else
            IFS= read -rs pass < /dev/tty
        fi
        printf '\n' >&2
        echo "$pass" > "$tmpfile"
        local result
        result=$(cat "$tmpfile")
        rm -f "$tmpfile"
        trap - ERR
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
        echo "=== $title === (refreshing every 1 second, press 'q' to exit)" >&2
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
        echo "" >&2
        echo "=== $title ===" >&2
        echo -e "$description" >&2
        echo "" >&2
        local idx=1
        local tags=()
        local states=()
        while [ $# -ge 3 ]; do
            echo "  $idx) [$3] $1" >&2
            tags+=("$2")
            states+=("$3")
            shift 3
            idx=$((idx + 1))
        done
        echo "" >&2
        echo "Enter numbers to toggle (comma-separated), empty to finish:" >&2
        local choices
        read -rp "> " choices < /dev/tty
        local result=""
        if [ -n "$choices" ]; then
            local choice
            for choice in $(echo "$choices" | tr ',' ' '); do
                if [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ] 2>/dev/null; then
                    [ -n "$result" ] && result="$result "
                    result="$result${tags[$((choice - 1))]}"
                else
                    echo "Invalid choice: $choice" >&2
                fi
            done
        fi
        echo "$result"
        return 0
    fi
}

## ASCII Art TUI Functions (raw backend enhancements)

tui_animated_intro() {
    local subtitle="${1:-Mac Pro Conversion and Management Tool}"
    source "$LIB_DIR/animated_header.sh" 2>/dev/null
    if declare -f tui_animated_header >/dev/null 2>&1; then
        tui_animated_header "$subtitle" 0.15 0
    else
        tui_cool_header "$subtitle"
    fi
}

tui_cool_header() {
    local subtitle="${1:-Mac Pro Conversion and Management Tool}"
    local art=" _   _ _                 _   _  __       
| | | | |__  _   _ _ __ | |_(_)/ _|_   _ 
| | | | '_ \| | | | '_ \| __| | |_| | | |
| _  | |_) | |_| | | | | |_| |  _| |_| |
|_| |_|_.__/ \__,_|_| |_|\__|_|_|  \__, |
                                   |___/ "
    [ -z "$art" ] && command -v figlet >/dev/null 2>&1 && art=$(figlet -f standard "Ubuntify" 2>/dev/null)
    local max_width=0 line
    while IFS= read -r line; do
        [ "${#line}" -gt "$max_width" ] && max_width=${#line}
    done <<< "$art"
    [ "${#subtitle}" -gt "$max_width" ] && max_width=${#subtitle}
    max_width=$((max_width + 4))
    local bar=$(printf '%*s' $max_width '' | tr ' ' '─')
    echo ""
    echo -e "  \033[0;32m┌─${bar}─┐\033[0m"
    while IFS= read -r line; do
        printf "  \033[0;32m│\033[0m \033[1;32m%s\033[0m\033[0;32m%*s│\033[0m\n" "$line" $((max_width - ${#line})) ''
    done <<< "$art"
    printf "  \033[0;32m│\033[0m \033[1;32m%s\033[0m\033[0;32m%*s│\033[0m\n" "$subtitle" $((max_width - ${#subtitle} - 1)) ''
    echo -e "  \033[0;32m└─${bar}─┘\033[0m"
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
    printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
    printf '    ║ %s%*s ║\n' "$title" $((width - ${#title} - 1)) ''
    printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
    printf '%s' "$content" | while IFS= read -r line; do
        printf '    ║ %s%*s ║\n' "$line" $((width - ${#line} - 1)) ''
    done
    printf '    ╚%s╝\n' "$(printf '═%.0s' $(seq 1 "$width"))"
}

tui_section() {
    local title="$1"
    local width="${2:-76}"
    printf '\n'
    printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
    printf '    ║  %s %*s║\n' "$title" $((width - ${#title} - 3)) ''
    printf '    ╚%s╝\n' "$(printf '═%.0s' $(seq 1 "$width"))"
}

tui_checklist_box() {
    local title="$1"
    local description="$2"
    shift 2
    local size
    size=$(_tui_get_size)
    local width
    width=$(echo "$size" | cut -d' ' -f2)

    if [ "$TUI_BACKEND" = "dialog" ] || [ "$TUI_BACKEND" = "whiptail" ]; then
        tui_checklist "$title" "$description" "$@"
        return $?
    fi

    local idx=1
    local tags=()
    local states=()
    local labels=()
    printf '\n'
    printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 $((width - 4))))"
    printf '    ║  \033[1m%s\033[0m%*s║\n' "$title" $((width - ${#title} - 5)) ''
    printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 $((width - 4))))"
    [ -n "$description" ] && printf '    ║  \033[2m%s\033[0m%*s║\n' "$description" $((width - ${#description} - 5)) ''
    [ -n "$description" ] && printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 $((width - 4))))"
    while [ $# -ge 2 ]; do
        local label="$1"
        local tag="$2"
        labels+=("$label")
        tags+=("$tag")
        local state="[ ]"
        printf '    ║    %s  %d. %s%*s║\n' "$state" "$idx" "$label" $((width - ${#label} - 13)) ''
        shift 2
        idx=$((idx + 1))
    done
    printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 $((width - 4))))"
    printf '\n'
    printf '    \033[2mKeys: ↑↓ Navigate  │  SPACE Toggle  │  ENTER Confirm  │  Q Quit\033[0m\n'
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
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 $((width))))"
        printf '    ║  \033[1m%s\033[0m%*s║\n' "$title" $((width - ${#title} - 4)) ''
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        [ -n "$description" ] && printf '    ║  \033[2m%s\033[0m\n' "$description"
        [ -n "$description" ] && printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 "$width"))"
        local i=0
        for option in "${options[@]}"; do
            local marker="  "
            local checkbox="[ ]"
            if [ $i -eq $selected ]; then
                marker=" \033[36m▸\033[0m"
            fi
            if [ "${choices[$i]}" -eq 1 ]; then
                checkbox="[\033[32m█\033[0m]"
            fi
            if [ $i -eq $selected ]; then
                printf '    ║%s \033[1m%s\033[0m %s %s%*s║\n' "$marker" "$checkbox" "$((i + 1))." "$option" $((width - ${#option} - ${#checkbox} - ${#i} - 8)) ''
            else
                printf '    ║%s %s %s %s%*s║\n' "$marker" "$checkbox" "$((i + 1))." "$option" $((width - ${#option} - ${#checkbox} - ${#i} - 8)) ''
            fi
            i=$((i + 1))
        done
        printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))"
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
            printf '    \033[32m▸ Selected: %d item(s)\033[0m\n' "$sel_count"
        else
            printf '    \033[2m▸ No items selected\033[0m\n'
        fi
        printf '\n'
        printf '    \033[2m↑↓ Navigate  │  SPACE Toggle  │  ENTER Done  │  Q Cancel\033[0m\n'

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
                echo "$selected_tags"
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

    if [ "$TUI_BACKEND" = "dialog" ] || [ "$TUI_BACKEND" = "whiptail" ]; then
        return 0
    fi

    printf '\n'
    printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 $((total_width - 4))))"
    printf '    ║  \033[1m%s\033[0m%*s║\n' "$title" $((total_width - ${#title} - 5)) ''
    printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 $((total_width - 4))))"

    local idx=1
    while [ $# -ge 2 ]; do
        local left_label="$1"
        local left_tag="$2"
        shift 2
        local right_label=""
        local right_tag=""
        if [ $# -ge 2 ]; then
            right_label="$1"
            right_tag="$2"
            shift 2
        fi

        printf '    ║  [%s] %d. %s' ' ' "$idx" "$left_label"
        local pad=$((col1_width - ${#left_label} - ${#idx}))
        [ $pad -gt 0 ] && printf '%*s' "$pad" ''
        printf '      '
        if [ -n "$right_label" ]; then
            idx=$((idx + 1))
            printf '[%s] %d. %s' ' ' "$idx" "$right_label"
            pad=$((col2_width - ${#right_label} - ${#idx}))
            [ $pad -gt 0 ] && printf '%*s' "$pad" ''
        fi
        printf '  ║\n'
    done

    printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 $((total_width - 4))))"
    printf '\n'
    printf '    \033[2mKeys: SPACE Toggle  │  ENTER Execute\033[0m\n'
}
