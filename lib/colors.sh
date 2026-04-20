#!/bin/bash
#
# lib/colors.sh - Color constants for terminal output
#
# Provides standard and retro-themed color constants for consistent
# colored terminal output across the deployment scripts.
#

[ "${_COLORS_SH_SOURCED:-0}" -eq 1 ] && return 0
_COLORS_SH_SOURCED=1

# Standard colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Retro terminal theme — Amber monitor / green phosphor with modern accents
readonly AMBER='\033[0;33m'
readonly BRIGHT_AMBER='\033[1;33m'
readonly PHOSPHOR='\033[0;32m'
readonly BRIGHT_PHOSPHOR='\033[1;32m'
readonly CYAN='\033[0;36m'
readonly BRIGHT_CYAN='\033[1;36m'
readonly DIM='\033[2m'
readonly BOLD='\033[1m'
readonly UNDERLINE='\033[4m'
readonly WHITE='\033[0;37m'
readonly BRIGHT_WHITE='\033[1;37m'
readonly MAGENTA='\033[0;35m'
readonly BRIGHT_RED='\033[1;31m'

# Semantic retro aliases
readonly RETRO_BORDER="$PHOSPHOR"
readonly RETRO_TITLE="$BRIGHT_WHITE"
readonly RETRO_SELECTED="$BRIGHT_CYAN"
readonly RETRO_DESC="$CYAN"
readonly RETRO_DIM="$DIM"
readonly RETRO_ACCENT="$BRIGHT_PHOSPHOR"
readonly RETRO_WARN="$BRIGHT_AMBER"