#!/bin/bash
# Hybrid: Minimal Layout + Matrix Green Glow
# Captures the essence of the visual mockup in shell ANSI

C_DIM='\033[2m'
C_GREEN='\033[0;32m'
C_BRIGHT='\033[1;32m'
C_RESET='\033[0m'

tui_hybrid_header() {
    local subtitle="${1:-Mac Pro Conversion and Management Tool}"
    local delay="${2:-0.15}"

    local -a lines=(
        " _   _ _                 _   _  __       "
        "| | | | |__  _   _ _ __ | |_(_)/ _|_   _ "
        "| | | | '_ \| | | | '_ \| __| | |_| | | |"
        "| _  | |_) | |_| | | | | |_| |  _| |_| |"
        "|_| |_|_.__/ \__,_|_| |_|\__|_|_|  \__, |"
        "                                   |___/ "
    )

    local max_width=0
    for line in "${lines[@]}"; do
        [ "${#line}" -gt "$max_width" ] && max_width=${#line}
    done
    [ "${#subtitle}" -gt "$max_width" ] && max_width=${#subtitle}
    max_width=$((max_width + 4))
    local dashes=$(printf '%*s' $max_width '')

    echo ""
    printf '    \033[2m┌─%s─┐\033[0m\n' "$(printf '%*s' $max_width '' | tr ' ' '─')"

    for i in "${!lines[@]}"; do
        local padding=$((max_width - ${#lines[$i]}))
        printf '    \033[2m│\033[0m \033[0;32m%s\033[0m%*s \033[2m│\033[0m\n' "${lines[$i]}" $padding ''
        sleep "$delay"
    done

    printf '    \033[2m│\033[0m '
    for i in $(seq 1 ${#subtitle}); do
        printf '%s' "${subtitle:$((i-1)):1}"
        sleep 0.03
    done
    printf '%*s \033[2m│\033[0m\n' $((max_width - ${#subtitle} - 1)) ''

    printf '    \033[2m└─%s─┘\033[0m\n' "$(printf '%*s' $max_width '' | tr ' ' '─')"
    echo ""
}

# Animated version with color cycling
tui_hybrid_header_animated() {
    local subtitle="${1:-Mac Pro Conversion and Management Tool}"
    local delay="${2:-0.12}"

    local -a lines=(
        " _   _ _                 _   _  __       "
        "| | | | |__  _   _ _ __ | |_(_)/ _|_   _ "
        "| | | | '_ \| | | | '_ \| __| | |_| | | |"
        "| _  | |_) | |_| | | | | |_| |  _| |_| |"
        "|_| |_|_.__/ \__,_|_| |_|\__|_|_|  \__, |"
        "                                   |___/ "
    )

    local max_width=0
    for line in "${lines[@]}"; do
        [ "${#line}" -gt "$max_width" ] && max_width=${#line}
    done
    [ "${#subtitle}" -gt "$max_width" ] && max_width=${#subtitle}
    max_width=$((max_width + 4))
    local dashes=$(printf '%*s' $max_width '')

    # Staged reveal with pulsing green
    local phase=0
    local -a colors=("$C_DIM" "$C_GREEN" "$C_BRIGHT" "$C_GREEN")

    echo ""
    for i in "${!lines[@]}"; do
        local color="${colors[$((phase % 4))]}"
        local padding=$((max_width - ${#lines[$i]}))
        printf '    \033[2m┌─%s─┐\033[0m\n' "$(printf '%*s' $max_width '' | tr ' ' '─')"
        printf '    \033[2m│\033[0m %s%s%s%*s \033[2m│\033[0m\n' "$color" "${lines[$i]}" "$C_RESET" $padding ''
        sleep "$delay"
        phase=$((phase + 1))
    done

    local padding=$((max_width - ${#subtitle}))
    printf '    \033[2m│\033[0m %s%s%s%*s \033[2m│\033[0m\n' "$C_BRIGHT" "$subtitle" "$C_RESET" $padding ''
    printf '    \033[2m└─%s─┘\033[0m\n' "$(printf '%*s' $max_width '' | tr ' ' '─')"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    clear
    echo "Testing hybrid header (minimal + matrix green glow)..."
    sleep 1
    tui_hybrid_header "Mac Pro Conversion and Management Tool"
    echo ""
    read -p "Press Enter for animated version..."
    clear
    tui_hybrid_header_animated "Mac Pro Conversion and Management Tool"
fi