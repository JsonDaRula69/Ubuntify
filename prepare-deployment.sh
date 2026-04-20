#!/bin/bash
set -e
set -o pipefail
set -u
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

# CLI flags
DRY_RUN=0
VERBOSE=0
AGENT_MODE=0
CONFIRM_YES=0
JSON_OUTPUT=0
REMOTE_HOST=""
REMOTE_OPERATION=""

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ESP_NAME="CIDATA"
readonly ESP_SIZE="5g"

# Library path - can be overridden for testing
readonly LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/lib}"

# Source all library modules (new TUI architecture)
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/tui.sh"
source "$LIB_DIR/dryrun.sh"
source "$LIB_DIR/retry.sh"
source "$LIB_DIR/verify.sh"
source "$LIB_DIR/rollback.sh"
source "$LIB_DIR/detect.sh"
source "$LIB_DIR/disk.sh"
source "$LIB_DIR/autoinstall.sh"
source "$LIB_DIR/bless.sh"
source "$LIB_DIR/deploy.sh"
source "$LIB_DIR/revert.sh"

# Source remote.sh if it exists (for Manage mode)
if [ -f "$LIB_DIR/remote.sh" ]; then
    source "$LIB_DIR/remote.sh"
fi

export DRY_RUN
export AGENT_MODE
export JSON_OUTPUT
export CONFIRM_YES

# Resolve config file: try OUTPUT_DIR first (env var override), then default.
# After parse_conf we re-resolve if OUTPUT_DIR was set in the config.
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/.Ubuntu_Deployment}"
OUTPUT_DIR_INITIAL="$OUTPUT_DIR"
CONF_FILE="${OUTPUT_DIR}/deploy.conf"
# Track whether config was loaded from user's deploy.conf or the example template
_USING_EXAMPLE_CONF=0
if [ ! -f "$CONF_FILE" ]; then
    warn "deploy.conf not found — using defaults from deploy.conf.example"
    CONF_FILE="${LIB_DIR}/deploy.conf.example"
    _USING_EXAMPLE_CONF=1
fi

# Default values for config keys
USERNAME=""
REALNAME=""
PASSWORD_HASH=""
HOSTNAME="macpro-linux"
SSH_KEYS=""
SSH_KEYS_FILE=""
ENCRYPTION="plaintext"
WHURL=""

parse_conf() {
    local conf="$1"
    while IFS= read -r line; do
        # Skip empty lines and comments
        case "$line" in
            ''|'#'*|[[:space:]]'#'*) continue ;;
        esac
        # Split on first = only (values may contain =)
        local key="${line%%=*}"
        local value="${line#*=}"
        # Trim leading/trailing whitespace from key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # Strip surrounding double quotes from value (KEY="value" format)
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
        esac
        # Skip empty keys
        [ -z "$key" ] && continue
        case "$key" in
            # Identity
            USERNAME)       USERNAME="$value" ;;
            REALNAME)       REALNAME="$value" ;;
            PASSWORD_HASH)  PASSWORD_HASH="$value" ;;
            HOSTNAME)       HOSTNAME="$value" ;;
            # SSH keys (accumulated, one per line)
            SSH_KEY)        SSH_KEYS="${SSH_KEYS}${SSH_KEYS:+
}$value" ;;
            SSH_KEYS_FILE)  SSH_KEYS_FILE="$value" ;;
            # WiFi (existing)
            WIFI_SSID)      WIFI_SSID="$value" ;;
            WIFI_PASSWORD)  WIFI_PASSWORD="$value" ;;
            # Monitoring (existing)
            WEBHOOK_HOST)   WEBHOOK_HOST="$value" ;;
            WEBHOOK_PORT)   WEBHOOK_PORT="$value" ;;
            # Encryption
            ENCRYPTION)     ENCRYPTION="$value" ;;
            # Output directory
            OUTPUT_DIR)     OUTPUT_DIR="$value" ;;
            *)              warn "Unknown config key: $key" ;;
        esac
    done < "$conf"
}
parse_conf "$CONF_FILE" || die "Failed to load $CONF_FILE"

# When using the example template, strip __REPLACE__ placeholder values
# so prompt_config() correctly sees them as empty and prompts the user
if [ "$_USING_EXAMPLE_CONF" -eq 1 ]; then
    for var in USERNAME REALNAME PASSWORD_HASH WIFI_SSID WIFI_PASSWORD; do
        case "$(eval echo \"\$$var\")" in
            __REPLACE__|'') eval "$var=\"\"" ;;
        esac
    done
    # SSH_KEYS may contain __REPLACE__ (accumulated from SSH_KEY lines)
    case "$SSH_KEYS" in
        *__REPLACE__*) SSH_KEYS="" ;;
    esac
fi

# Re-resolve CONF_FILE if OUTPUT_DIR was set in config (different from initial)
if [ "$OUTPUT_DIR" != "${OUTPUT_DIR_INITIAL:-}" ] && [ -f "$OUTPUT_DIR/deploy.conf" ]; then
    CONF_FILE="$OUTPUT_DIR/deploy.conf"
fi

mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"

# Handle SSH_KEYS_FILE: read keys from file and prepend to SSH_KEYS
if [ -n "$SSH_KEYS_FILE" ] && [ -f "$SSH_KEYS_FILE" ]; then
    file_keys=""
    while IFS= read -r key_line; do
        case "$key_line" in
            ssh-*|ecdsa-*|sk-*) file_keys="${file_keys}${file_keys:+
}${key_line}" ;;
        esac
    done < "$SSH_KEYS_FILE"
    SSH_KEYS="${file_keys}${SSH_KEYS:+
${SSH_KEYS}}"
fi

# Compute derived values
if [ -n "$WEBHOOK_HOST" ]; then
    WEBHOOK_PORT="${WEBHOOK_PORT:-8080}"
    WHURL="http://${WEBHOOK_HOST}:${WEBHOOK_PORT}/webhook"
else
    WHURL=""
fi

export WIFI_SSID
export WIFI_PASSWORD
export WEBHOOK_HOST
export WEBHOOK_PORT
export WHURL
export USERNAME
export REALNAME
export PASSWORD_HASH
export HOSTNAME
export SSH_KEYS
export SSH_KEYS_FILE
export ENCRYPTION
export OUTPUT_DIR

# Global state for cleanup (exported so lib modules can access)
export INTERNAL_DISK=""
export APFS_CONTAINER=""
export _ESP_CREATED=0
export _APFS_RESIZED=0
export _APFS_ORIGINAL_SIZE=""
export TARGET_DEVICE=""
export _CLEANUP_DONE=0

# User selections (exported for lib modules)
export DEPLOY_METHOD=""
export STORAGE_LAYOUT=""
export NETWORK_TYPE=""

generate_password_hash() {
    local password="$1"
    openssl passwd -6 "$password" 2>/dev/null
}

prompt_config() {
    local missing=0

    if [ -z "$USERNAME" ]; then
        if [ "$AGENT_MODE" -eq 1 ]; then
            agent_error "USERNAME required in deploy.conf or --agent mode"
            missing=1
        else
            USERNAME=$(tui_input "Username" "Enter username for the Ubuntu system:" "")
            [ -z "$USERNAME" ] && { die "Username is required"; }
        fi
    fi
    if [ -z "$REALNAME" ]; then
        if [ "$AGENT_MODE" -eq 1 ]; then
            REALNAME="$USERNAME"
        else
            REALNAME=$(tui_input "Full Name" "Enter full name (GECOS):" "$USERNAME")
        fi
    fi
    if [ -z "$PASSWORD_HASH" ]; then
        if [ "$AGENT_MODE" -eq 1 ]; then
            agent_error "PASSWORD_HASH required in deploy.conf or --agent mode"
            missing=1
        else
            local password password2
            password=$(tui_password "Password" "Enter password for $USERNAME:")
            password2=$(tui_password "Confirm Password" "Confirm password:")
            if [ "$password" != "$password2" ]; then
                die "Passwords do not match"
            fi
            PASSWORD_HASH=$(generate_password_hash "$password") || die "Failed to generate password hash"
        fi
    fi
    if [ -z "$SSH_KEYS" ] && [ -z "$SSH_KEYS_FILE" ]; then
        if [ "$AGENT_MODE" -eq 1 ]; then
            agent_error "SSH_KEY or SSH_KEYS_FILE required in deploy.conf"
            missing=1
        else
            local ssh_choice
            ssh_choice=$(prompt_ssh_key_menu) || { ssh_choice="skip"; }
            case "$ssh_choice" in
                existing)
                    local selected_key
                    selected_key=$(prompt_ssh_key_selection)
                    if [ "$selected_key" = "SKIP" ]; then
                        warn "SSH keys skipped by user"
                    elif [ "$selected_key" = "MANUAL" ]; then
                        local manual_key
                        manual_key=$(tui_input "SSH Public Key" "Paste your SSH public key:" "")
                        if [ -n "$manual_key" ]; then
                            SSH_KEYS="$manual_key"
                        fi
                    elif [ -n "$selected_key" ]; then
                        SSH_KEYS="$selected_key"
                    fi
                    ;;
                generate)
                    local generated_key
                    generated_key=$(prompt_generate_key)
                    if [ -n "$generated_key" ]; then
                        SSH_KEYS="$generated_key"
                    fi
                    ;;
                skip)
                    warn "No SSH keys configured. You will need console access to the Mac Pro."
                    ;;
            esac
        fi
    elif [ "$AGENT_MODE" -ne 1 ]; then
        log_info "SSH keys already configured from deploy.conf (${#SSH_KEYS} bytes)"
    fi
    if [ -z "$WIFI_SSID" ]; then
        if [ "$AGENT_MODE" -eq 1 ]; then
            agent_error "WIFI_SSID required in deploy.conf or --agent mode"
            missing=1
        else
            WIFI_SSID=$(tui_input "WiFi SSID" "Enter WiFi network name:" "")
        fi
    fi
    if [ -z "$WIFI_PASSWORD" ]; then
        if [ "$AGENT_MODE" -eq 1 ]; then
            agent_error "WIFI_PASSWORD required in deploy.conf or --agent mode"
            missing=1
        else
            WIFI_PASSWORD=$(tui_password "WiFi Password" "Enter WiFi password:")
        fi
    fi
    if [ -z "$WEBHOOK_HOST" ]; then
        if [ "$AGENT_MODE" -eq 1 ]; then
            WEBHOOK_HOST="localhost"
        else
            WEBHOOK_HOST=$(tui_input "Webhook Host" "Enter monitoring host IP (default: localhost):" "localhost")
        fi
    fi
    if [ -z "$WEBHOOK_PORT" ]; then
        WEBHOOK_PORT="${WEBHOOK_PORT:-8080}"
    fi

    if [ "$AGENT_MODE" -ne 1 ]; then
        configure_ssh_config
    fi

    if [ "$missing" -eq 1 ]; then
        return 1
    fi

    WHURL="http://${WEBHOOK_HOST}:${WEBHOOK_PORT}/webhook"
    export USERNAME REALNAME PASSWORD_HASH HOSTNAME SSH_KEYS SSH_KEYS_FILE
    export WIFI_SSID WIFI_PASSWORD WEBHOOK_HOST WEBHOOK_PORT WHURL
    return 0
}

# ── SSH Key Management Functions ──

scan_ssh_keys() {
    local key_files=""
    for f in ~/.ssh/*.pub; do
        if [ -f "$f" ]; then
            key_files="${key_files}${key_files:+
}${f}"
        fi
    done
    echo "$key_files"
}

get_key_comment() {
    local key_path="$1"
    if [ -f "$key_path" ]; then
        cut -d' ' -f3 "$key_path" 2>/dev/null | head -1
    fi
}

get_key_type() {
    local key_path="$1"
    if [ -f "$key_path" ]; then
        cut -d' ' -f1 "$key_path" 2>/dev/null | cut -d'-' -f2 | head -1
    fi
}

prompt_ssh_key_selection() {
    local available_keys
    available_keys=$(scan_ssh_keys)

    if [ -z "$available_keys" ]; then
        return 1
    fi

    local key_count=0
    local key_files=""
    local key_labels=""

    while IFS= read -r key_file; do
        [ -z "$key_file" ] && continue
        key_count=$((key_count + 1))
        local key_type
        key_type=$(get_key_type "$key_file")
        local key_comment
        key_comment=$(get_key_comment "$key_file")
        local label
        label=$(basename "$key_file")
        if [ -n "$key_comment" ]; then
            label="${label} (${key_type}, ${key_comment})"
        else
            label="${label} (${key_type})"
        fi
        key_files="${key_files}${key_files:+|}${key_file}"
        key_labels="${key_labels}${key_labels:+|}${label}"
    done <<EOF
$available_keys
EOF

    if [ "$key_count" -eq 0 ]; then
        return 1
    fi

    # Build menu items using positional args for tui_menu
    # tui_menu takes pairs: "Display Text" "tag_value"
    local menu_args=""
    local idx=1
    local IFS_OLD="$IFS"
    IFS='|'
    for label in $key_labels; do
        menu_args="${menu_args} \"${label}\" \"${idx}\""
        idx=$((idx + 1))
    done
    IFS="$IFS_OLD"
    menu_args="${menu_args} \"Paste key manually...\" \"manual\" \"Skip SSH keys\" \"skip\""

    local selection
    selection=$(eval "tui_menu \"SSH Public Key\" \"Select SSH public key to use:\" $menu_args") || return 1

    if [ "$selection" = "skip" ]; then
        echo "SKIP"
        return 0
    elif [ "$selection" = "manual" ]; then
        echo "MANUAL"
        return 0
    fi

    # Find the selected key file by index
    local target_idx=$((selection - 1))
    local current_idx=0
    local selected_path=""
    IFS='|'
    for path in $key_files; do
        if [ "$current_idx" -eq "$target_idx" ]; then
            selected_path="$path"
            break
        fi
        current_idx=$((current_idx + 1))
    done
    IFS="$IFS_OLD"

    if [ -n "$selected_path" ]; then
        cat "$selected_path"
    fi
}

prompt_ssh_key_menu() {
    local choice
    choice=$(tui_menu "SSH Key Configuration" "Choose how to provide SSH public key:" \
        "Provide existing key" "existing" \
        "Generate new key" "generate" \
        "Skip SSH setup" "skip") || return 1
    echo "$choice"
}

prompt_generate_key() {
    local key_type_choice
    key_type_choice=$(tui_menu "Generate SSH Key" "Select key type:" \
        "ed25519 (recommended)" "ed25519" \
        "rsa (4096-bit)" "rsa") || return 1

    local key_file="$HOME/.ssh/macpro_ubuntu_${key_type_choice}"
    local key_path="${key_file}.pub"

    if [ -f "$key_file" ]; then
        if ! tui_confirm "Key Exists" "Key $key_file already exists.\n\nOverwrite?"; then
            return 1
        fi
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    local actual_user="${SUDO_USER:-$USER}"

    log_info "Generating SSH key pair: $key_type_choice..."
    if [ "$key_type_choice" = "ed25519" ]; then
        ssh-keygen -t ed25519 -C "macpro-ubuntu-$(date +%Y%m%d)" -f "$key_file" -N "" 2>/dev/null || {
            warn "Failed to generate ed25519 key"
            return 1
        }
    else
        ssh-keygen -t rsa -b 4096 -C "macpro-ubuntu-$(date +%Y%m%d)" -f "$key_file" -N "" 2>/dev/null || {
            warn "Failed to generate RSA key"
            return 1
        }
    fi

    chown "$actual_user" "$key_file" "$key_file.pub" 2>/dev/null || true
    chown "$actual_user" "$HOME/.ssh" 2>/dev/null || true
    log_info "Key generated: $key_file (owner: $actual_user)"
    if [ -f "$key_path" ]; then
        cat "$key_path"
    fi
}

configure_ssh_config() {
    local ssh_config="$HOME/.ssh/config"
    local macpro_ip=""
    local user="$USERNAME"
    local actual_user="${SUDO_USER:-$USER}"

    if [ -z "$user" ]; then
        user="ubuntu"
    fi

    local needs_config=0
    local has_macpro=0
    local has_macpro_linux=0

    if [ -f "$ssh_config" ]; then
        while IFS= read -r line; do
            case "$line" in
                *"Host macpro-linux"*) has_macpro_linux=1 ;;
                *"Host macpro"*) has_macpro=1 ;;
            esac
        done < "$ssh_config"
    fi

    if [ "$has_macpro" -eq 0 ] || [ "$has_macpro_linux" -eq 0 ]; then
        needs_config=1
    fi

    if [ "$needs_config" -eq 0 ]; then
        return 0
    fi

    if ! tui_confirm "SSH Config" "Would you like to add Host entries to ~/.ssh/config for:\n\n  Host macpro (macOS)\n  Host macpro-linux (Ubuntu via mDNS)\n\nThis makes SSH connections easier."; then
        return 0
    fi

    if [ "$has_macpro" -eq 0 ]; then
        macpro_ip=$(tui_input "macOS Host IP" "Enter macOS IP address (or leave empty to skip):" "")
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [ -f "$ssh_config" ]; then
        while IFS= read -r line; do
            case "$line" in
                "# macpro-deploy"*|"# End macpro-deploy"*)
                    continue
                    ;;
            esac
            echo "$line"
        done < "$ssh_config" > "$ssh_config.tmp" 2>/dev/null || true
        mv "$ssh_config.tmp" "$ssh_config" 2>/dev/null || true
    fi

    {
        echo ""
        echo "# macpro-deploy generated entries"
        if [ "$has_macpro" -eq 0 ] && [ -n "$macpro_ip" ]; then
            echo "Host macpro"
            echo "    HostName $macpro_ip"
            echo "    User $user"
            echo ""
        fi
        if [ "$has_macpro_linux" -eq 0 ]; then
            echo "Host macpro-linux"
            echo "    HostName macpro-linux.local"
            echo "    User $user"
            echo ""
        fi
        echo "# End macpro-deploy"
    } >> "$ssh_config"

    chmod 600 "$ssh_config"
    chown "$actual_user" "$ssh_config" 2>/dev/null || true
    chown "$actual_user" "$HOME/.ssh" 2>/dev/null || true
    log_info "SSH config updated: $ssh_config (owner: $actual_user)"
}

# ── Pre-execution Summary ──

show_pre_execution_summary() {
    local storage_method="$1"
    local network_method="$2"

    local method_name="Unknown"
    case "${DEPLOY_METHOD:-}" in
        1) method_name="Internal partition (ESP)" ;;
        2) method_name="USB drive" ;;
        3) method_name="Full manual" ;;
        4) method_name="VM test (VirtualBox)" ;;
    esac

    local storage_name="Unknown"
    case "$storage_method" in
        1) storage_name="Dual-boot (preserve macOS)" ;;
        2) storage_name="Full disk (replace macOS)" ;;
    esac

    local network_name="Unknown"
    case "$network_method" in
        1) network_name="WiFi only" ;;
        2) network_name="Ethernet available" ;;
    esac

    local ssh_key_count=0
    if [ -n "$SSH_KEYS" ]; then
        while IFS= read -r key; do
            [ -n "$key" ] && ssh_key_count=$((ssh_key_count + 1))
        done <<EOF
$SSH_KEYS
EOF
    fi

    local summary=""
    summary="Configuration Summary:\n\n"
    summary="${summary}Username:    ${USERNAME}\n"
    summary="${summary}Hostname:    ${HOSTNAME}\n"
    summary="${summary}Real Name:   ${REALNAME}\n"
    summary="${summary}WiFi SSID:   ${WIFI_SSID:-(not set)}\n"
    summary="${summary}Webhook:     ${WEBHOOK_HOST}:${WEBHOOK_PORT}\n"
    summary="${summary}SSH Keys:    ${ssh_key_count} key(s)\n"
    summary="${summary}\n"
    summary="${summary}Deployment Method: ${method_name}\n"
    summary="${summary}Storage Layout:      ${storage_name}\n"
    summary="${summary}Network Type:        ${network_name}\n"
    summary="${summary}\n"
    summary="${summary}Proceed with deployment?"

    tui_confirm "Confirm Configuration" "$summary"
}

_conf_escape() {
    printf '%s' "$1" | awk '{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); print}'
}

save_config() {
    local conf="${1:-$CONF_FILE}"
    if [ "$AGENT_MODE" -eq 1 ]; then
        agent_output "config" "deploy.conf path" "$conf"
    fi
    {
        printf '# deploy.conf — Generated by prepare-deployment.sh\n'
        printf '# Edit this file to customize future deployments\n'
        printf 'USERNAME="%s"\n' "$(_conf_escape "$USERNAME")"
        printf 'REALNAME="%s"\n' "$(_conf_escape "$REALNAME")"
        printf 'HOSTNAME="%s"\n' "$(_conf_escape "$HOSTNAME")"
        printf 'PASSWORD_HASH="%s"\n' "$(_conf_escape "$PASSWORD_HASH")"
    } > "$conf"
    # Write SSH keys (one per line)
    if [ -n "$SSH_KEYS" ]; then
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            printf 'SSH_KEY="%s"\n' "$(_conf_escape "$key")"
        done <<EOF
$SSH_KEYS
EOF
    fi >> "$conf"
    if [ -n "$SSH_KEYS_FILE" ]; then
        printf 'SSH_KEYS_FILE="%s"\n' "$(_conf_escape "$SSH_KEYS_FILE")"
    fi >> "$conf"
    {
        printf 'WIFI_SSID="%s"\n' "$(_conf_escape "$WIFI_SSID")"
        printf 'WIFI_PASSWORD="%s"\n' "$(_conf_escape "$WIFI_PASSWORD")"
        printf 'WEBHOOK_HOST="%s"\n' "$(_conf_escape "$WEBHOOK_HOST")"
        printf 'WEBHOOK_PORT="%s"\n' "$(_conf_escape "$WEBHOOK_PORT")"
        printf 'ENCRYPTION="%s"\n' "$(_conf_escape "$ENCRYPTION")"
        printf 'OUTPUT_DIR="%s"\n' "$(_conf_escape "$OUTPUT_DIR")"
    } >> "$conf"
    chmod 600 "$conf"
}

encrypt_config() {
    local conf="${1:-$CONF_FILE}"
    case "$ENCRYPTION" in
        plaintext)
            chmod 600 "$conf"
            ;;
        aes256)
            local enc_file="${conf}.enc"
            openssl enc -aes-256-cbc -pbkdf2 -salt -in "$conf" -out "$enc_file" || die "Failed to encrypt config"
            rm -f "$conf"
            chmod 600 "$enc_file"
            log "Config encrypted to ${enc_file} (plaintext config removed)"
            ;;
        keychain)
            if [ "$(uname)" != "Darwin" ]; then
                die "Keychain encryption only available on macOS"
            fi
            security add-generic-password -a "macpro-deploy" -s "macpro-deploy-conf" -w "$(cat "$conf")" -U 2>/dev/null || \
                die "Failed to store config in macOS Keychain"
            chmod 600 "$conf"
            log "Config stored in macOS Keychain"
            ;;
        *)
            die "Unknown encryption mode: $ENCRYPTION (use: plaintext, aes256, keychain)"
            ;;
    esac
}

decrypt_config() {
    local conf="${1:-$CONF_FILE}"
    local enc_file="${conf}.enc"

    if [ -f "$enc_file" ]; then
        openssl enc -aes-256-cbc -pbkdf2 -d -in "$enc_file" -out "$conf" || die "Failed to decrypt config"
        log "Config decrypted from ${enc_file}"
    elif [ "$(uname)" = "Darwin" ]; then
        local stored
        stored=$(security find-generic-password -a "macpro-deploy" -s "macpro-deploy-conf" -w 2>/dev/null) || true
        if [ -n "$stored" ]; then
            echo "$stored" > "$conf"
            chmod 600 "$conf"
            log "Config restored from macOS Keychain"
        fi
    fi
}

show_help() {
    echo "Usage: sudo ./prepare-deployment.sh [OPTIONS]"
    echo ""
    echo "Ubuntify - Mac Pro Conversion Tool v0.2.43"
    echo ""
    echo "Options:"
    echo "  --dry-run             Show what would be done without making changes"
    echo "  --verbose             Enable verbose logging"
    echo "  --revert              Revert previous deployment changes"
    echo "  --help                Show this help message"
    echo ""
    echo "Agent Mode (non-interactive, for LLM agents):"
    echo "  --agent               Enable agent mode (non-interactive, JSON output)"
    echo "  --yes                 Auto-confirm all prompts (use with --agent)"
    echo "  --json                Output structured JSON (auto-set by --agent)"
    echo "  --method 1|2|3|4     Deployment method (1=ESP, 2=USB, 3=manual, 4=VM)"
    echo "  --storage 1|2         Storage layout (1=dual-boot, 2=full-disk)"
    echo "  --network 1|2         Network type (1=WiFi, 2=Ethernet)"
    echo "  --host HOST           Remote host for Manage mode (default: macpro-linux)"
    echo "  --operation OP        Manage mode operation (see README)"
    echo "  --wifi-ssid SSID      Override WiFi SSID from deploy.conf"
    echo "  --wifi-password PASS  Override WiFi password from deploy.conf"
    echo "  --webhook-host HOST   Override webhook host from deploy.conf"
    echo "  --webhook-port PORT   Override webhook port from deploy.conf"
    echo "  --username USER       Override username from deploy.conf"
    echo "  --hostname HOST       Override hostname from deploy.conf"
    echo "  --vm                  Use VM test mode (autoinstall-vm.yaml)"
    echo "  --output-dir DIR      Override runtime output directory (default: ~/.Ubuntu_Deployment/)"
    echo ""
    echo "Modes:"
    echo "  Deploy   - Local operations: Build ISO, deploy to ESP/USB/VM, monitor"
    echo "  Manage   - Remote SSH operations (requires lib/remote.sh)"
    echo ""
    echo "Without flags, the TUI menu will start."
    echo ""
    echo "Exit Codes:"
    echo "  0  Success"
    echo "  1  General error"
    echo "  2  Usage error (missing/invalid arguments)"
    echo "  3  Config error"
    echo "  4  Pre-flight check failed"
    echo "  5  Partial success"
    echo "  6  Missing dependency"
    echo "  7  Network error"
    echo "  8  Disk error"
    echo "  9  Timeout"
    echo "  10 Authentication error"
    echo "  11 Dry-run completed (no changes made)"
    echo "  12 Agent mode: missing required parameter"
    echo "  13 Agent mode: confirmation denied"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)           DRY_RUN=1; shift ;;
        --verbose)           VERBOSE=1; shift ;;
        --agent)             AGENT_MODE=1; JSON_OUTPUT=1; shift ;;
        --yes)               CONFIRM_YES=1; shift ;;
        --json)              JSON_OUTPUT=1; shift ;;
        --method)            DEPLOY_METHOD="$2"; shift 2 ;;
        --method=*)          DEPLOY_METHOD="${1#*=}"; shift ;;
        --storage)           STORAGE_LAYOUT="$2"; shift 2 ;;
        --storage=*)         STORAGE_LAYOUT="${1#*=}"; shift ;;
        --network)           NETWORK_TYPE="$2"; shift 2 ;;
        --network=*)         NETWORK_TYPE="${1#*=}"; shift ;;
        --host)              REMOTE_HOST="$2"; shift 2 ;;
        --host=*)            REMOTE_HOST="${1#*=}"; shift ;;
        --operation)         REMOTE_OPERATION="$2"; shift 2 ;;
        --operation=*)       REMOTE_OPERATION="${1#*=}"; shift ;;
        --wifi-ssid)         WIFI_SSID="$2"; shift 2 ;;
        --wifi-ssid=*)       WIFI_SSID="${1#*=}"; shift ;;
        --wifi-password)     WIFI_PASSWORD="$2"; shift 2 ;;
        --wifi-password=*)   WIFI_PASSWORD="${1#*=}"; shift ;;
        --webhook-host)      WEBHOOK_HOST="$2"; shift 2 ;;
        --webhook-host=*)    WEBHOOK_HOST="${1#*=}"; shift ;;
        --webhook-port)      WEBHOOK_PORT="$2"; shift 2 ;;
        --webhook-port=*)    WEBHOOK_PORT="${1#*=}"; shift ;;
        --username)          USERNAME="$2"; shift 2 ;;
        --username=*)        USERNAME="${1#*=}"; shift ;;
        --hostname)          HOSTNAME="$2"; shift 2 ;;
        --hostname=*)        HOSTNAME="${1#*=}"; shift ;;
        --vm)                DEPLOY_METHOD=4; shift ;;
        --output-dir)        OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*)      OUTPUT_DIR="${1#*=}"; shift ;;
        --revert)            handle_revert_flag "--revert"; exit $? ;;
        --help|-h)           show_help ;;
        *)                   echo "Unknown option: $1"; show_help ;;
    esac
done

if [ "$VERBOSE" -eq 1 ]; then
    LOG_LEVEL="$LOG_LEVEL_DEBUG"
fi

# ── Mode Selection ──

select_mode() {
    tui_ascii_header "Ubuntu 24.04 LTS · Mac Pro 2013"

    if [ "$TUI_BACKEND" = "raw" ]; then
        local width=76
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        printf '    ║  \033[1mSELECT OPERATION\033[0m%*s║\n' $((width - 20)) ''
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        printf '    ║%*s║\n' $((width + 1)) ''
        printf '    ║    [ ]  1. Deploy Ubuntu         Install Ubuntu on Mac Pro SSD        ║\n'
        printf '    ║    [ ]  2. Manage System         Kernel · WiFi · Storage · Updates    ║\n'
        printf '    ║    [ ]  3. Revert Failed Deploy  Rollback interrupted installation     ║\n'
        printf '    ║    [ ]  4. Exit                  Quit                                  ║\n'
        printf '    ║%*s║\n' $((width + 1)) ''
        printf '    ╚%s╝\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        printf '\n'
        printf '    \033[2mKeys: SPACE Toggle  │  ENTER Execute\033[0m\n'
        printf '\n'
        printf '    > '

        local choice_num
        read -r choice_num < /dev/tty
        case "$choice_num" in
            1) echo "deploy" ;;
            2) echo "manage" ;;
            3) echo "revert" ;;
            4) echo "exit" ;;
            *) echo "exit" ;;
        esac
    else
        local choice
        choice=$(tui_menu "Ubuntify" "Select operation mode:" "Deploy" "deploy" "Manage" "manage" "Revert Failed Deploy" "revert" "Exit" "exit") || exit 0
        echo "$choice"
    fi
}

# ── Deploy Mode Sub-menus ──

deploy_menu() {
    local choice
    choice=$(tui_menu "Deploy Mode" "Select deployment operation:" \
        "Build ISO" "build_iso" \
        "Deploy" "deploy" \
        "Monitor" "monitor" \
        "Test in VM" "test_vm" \
        "Revert" "revert" \
        "Back to Main Menu" "back") || return 1
    echo "$choice"
}

menu_build_iso() {
    if [ ! -f "$LIB_DIR/build-iso.sh" ]; then
        tui_msgbox "Error" "build-iso.sh not found in $LIB_DIR"
        return 1
    fi

    if ! tui_confirm "Build ISO" "This will build the Ubuntu ISO with custom packages and autoinstall configuration.\n\nProceed?"; then
        return 1
    fi

    echo "[....] Building Ubuntu ISO — this will take 5-10 minutes..." >&2
    log_info "Starting ISO build process..."
    local log_path
    log_path="$(log_get_file_path)"
    "$LIB_DIR/build-iso.sh" 2>&1 | tee -a "$log_path" | tui_progress "Building Ubuntu ISO"
    local build_rc=${PIPESTATUS[0]:-$?}

    if [ "$build_rc" -ne 0 ]; then
        echo "[FAIL] ISO build failed (exit $build_rc)" >&2
        tui_msgbox "Build Failed" "ISO build failed (exit $build_rc).\n\nCheck log: $log_path"
    else
        echo "[ OK ] ISO build complete" >&2
        tui_msgbox "Build Complete" "ISO built successfully.\n\nOutput: ${OUTPUT_DIR:-$HOME/.Ubuntu_Deployment}/ubuntu-macpro.iso"
    fi
}

menu_deploy() {
    local method
    method=$(tui_menu "Select Deployment Method" "Choose how to deploy Ubuntu:" \
        "Internal partition (ESP)" "1" \
        "USB drive" "2" \
        "Full manual" "3" \
        "VM test (VirtualBox)" "4" \
        "Cancel" "cancel") || return 1

    if [ "$method" = "cancel" ]; then
        return 1
    fi

    DEPLOY_METHOD="$method"

    local storage=""
    local network=""

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        storage=$(tui_menu "Select Storage Layout" "Choose partition scheme:" \
            "Dual-boot (preserve macOS)" "1" \
            "Full disk (replace macOS)" "2" \
            "Cancel" "cancel") || return 1
        [ "$storage" = "cancel" ] && return 1
        STORAGE_LAYOUT="$storage"

        network=$(tui_menu "Select Network Type" "Choose network configuration:" \
            "WiFi only (Broadcom BCM4360)" "1" \
            "Ethernet available" "2" \
            "Cancel" "cancel") || return 1
        [ "$network" = "cancel" ] && return 1
        NETWORK_TYPE="$network"
    fi

    if ! show_pre_execution_summary "$STORAGE_LAYOUT" "$NETWORK_TYPE"; then
        return 1
    fi

    log_info "Starting deployment with method $DEPLOY_METHOD..."

    local deploy_rc=0
    case "$DEPLOY_METHOD" in
        1)
            deploy_internal_partition || deploy_rc=$?
            ;;
        2)
            deploy_usb || deploy_rc=$?
            ;;
        3)
            deploy_manual || deploy_rc=$?
            ;;
        4)
            deploy_vm_test || deploy_rc=$?
            ;;
    esac

    if [ "$deploy_rc" -ne 0 ]; then
        tui_msgbox "Deployment Failed" "Deployment exited with error code $deploy_rc.\n\nCheck log: $(log_get_file_path)"
        return 1
    fi

    tui_msgbox "Deployment Complete" "Deployment preparation complete!\n\nLog: $(log_get_file_path)"
}

menu_monitor() {
    local monitor_dir="$SCRIPT_DIR/macpro-monitor"

    if [ ! -f "$monitor_dir/server.js" ]; then
        tui_msgbox "Error" "Monitor server not found at $monitor_dir/server.js"
        return 1
    fi

    local choice
    choice=$(tui_menu "Monitor" "Select monitor action:" \
        "Start monitor" "start" \
        "View logs" "logs" \
        "Stop monitor" "stop" \
        "Back" "back") || return 1

    case "$choice" in
        start)
            if [ -f "$monitor_dir/start.sh" ] && bash "$monitor_dir/start.sh" >/dev/null 2>&1; then
                tui_msgbox "Monitor Started" "Monitor is now running.\n\nDashboard: http://localhost:8080\nWebhook: http://localhost:8080/webhook"
            else
                tui_msgbox "Monitor Failed" "Failed to start monitor. Check logs."
            fi
            ;;
        logs)
            if [ -f "$monitor_dir/server.log" ]; then
                tui_tailbox "Monitor Logs" "$monitor_dir/server.log"
            else
                tui_msgbox "No Logs" "Monitor log not found"
            fi
            ;;
        stop)
            if [ -f "$monitor_dir/stop.sh" ]; then
                bash "$monitor_dir/stop.sh" >/dev/null 2>&1
                tui_msgbox "Monitor Stopped" "Monitor stopped."
            else
                tui_msgbox "Not Running" "Monitor is not running."
            fi
            ;;
    esac
}

menu_test_vm() {
    local vm_dir="$SCRIPT_DIR/tests/vm"
    local choice
    choice=$(tui_menu "VM Test" "Select VM test action:" \
        "Build VM ISO" "build" \
        "Create VM" "create" \
        "Run VM" "run" \
        "SSH to VM" "ssh" \
        "Stop VM" "stop" \
        "View serial log" "serial" \
        "Back" "back") || return 1

    case "$choice" in
        build)
            if [ -f "$LIB_DIR/build-iso.sh" ]; then
                log_info "Building VM ISO..."
                sudo "$LIB_DIR/build-iso.sh" --vm 2>&1 | tee -a "$(log_get_file_path)" | tui_progress "Building VM ISO"
                tui_msgbox "Build Complete" "VM ISO built.\n\nOutput: ${OUTPUT_DIR}/ubuntu-vmtest.iso"
            else
                tui_msgbox "Error" "lib/build-iso.sh not found"
            fi
            ;;
        create)
            if [ -f "$vm_dir/create-vm.sh" ]; then
                log_info "Creating VM..."
                "$vm_dir/create-vm.sh"
                tui_msgbox "VM Created" "VirtualBox VM created.\n\nUse 'Run VM' to start."
            else
                tui_msgbox "Error" "create-vm.sh not found in $vm_dir"
            fi
            ;;
        run)
            if [ -f "$vm_dir/test-vm.sh" ]; then
                log_info "Starting VM..."
                "$vm_dir/test-vm.sh" run
            else
                tui_msgbox "Error" "test-vm.sh not found in $vm_dir"
            fi
            ;;
        ssh)
            if [ -f "$vm_dir/test-vm.sh" ]; then
                "$vm_dir/test-vm.sh" ssh
            else
                tui_msgbox "Error" "test-vm.sh not found in $vm_dir"
            fi
            ;;
        stop)
            if [ -f "$vm_dir/test-vm.sh" ]; then
                "$vm_dir/test-vm.sh" stop
                tui_msgbox "VM Stopped" "VM has been powered off."
            else
                tui_msgbox "Error" "test-vm.sh not found in $vm_dir"
            fi
            ;;
        serial)
            if [ -f /tmp/vmtest-serial.log ]; then
                tui_tailbox "Serial Log" "/tmp/vmtest-serial.log"
            else
                tui_msgbox "No Serial Log" "Serial log not found at /tmp/vmtest-serial.log"
            fi
            ;;
    esac
}

menu_revert() {
    local revert_msg="This will revert all deployment changes:
- Remove ESP partition if created
- Restore APFS container size if resized
- Restore macOS boot device"

    if command -v journal_read >/dev/null 2>&1; then
        journal_read
        if [ -n "${JOURNAL_PHASE:-}" ]; then
            revert_msg="${revert_msg}

Last incomplete phase: ${JOURNAL_PHASE}
Deploy method: ${JOURNAL_DEPLOY_METHOD:-unknown}"
        fi
    fi

    if ! tui_confirm "Revert Deployment" "${revert_msg}

Proceed?"; then
        return 1
    fi

    log_info "Reverting deployment changes..."
    if command -v rollback_from_journal >/dev/null 2>&1; then
        rollback_from_journal
    else
        revert_changes
    fi

    if command -v show_recovery_instructions >/dev/null 2>&1; then
        show_recovery_instructions
    fi

    if command -v journal_destroy >/dev/null 2>&1; then
        journal_destroy
    fi

    tui_msgbox "Revert Complete" "Deployment changes have been reverted."
}

run_deploy_mode() {
    while true; do
        local choice
        choice=$(deploy_menu) || break

        case "$choice" in
            build_iso)   menu_build_iso ;;
            deploy)      menu_deploy ;;
            monitor)     menu_monitor ;;
            test_vm)     menu_test_vm ;;
            revert)      menu_revert ;;
            back)        break ;;
        esac
    done
}

# ── Manage Mode Sub-menus ──

manage_menu() {
    tui_ascii_header

    if [ "$TUI_BACKEND" = "raw" ]; then
        local width=76
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        printf '    ║  \033[1mSYSTEM MANAGEMENT\033[0m%*s║\n' $((width - 22)) ''
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        printf '    ║%*s║\n' $((width + 1)) ''
        printf '    ║    [ ]  1. System Info         View kernel, WiFi, disk, DKMS status   ║\n'
        printf '    ║    [ ]  2. Kernel Management    Status, Pin, Update, Security          ║\n'
        printf '    ║    [ ]  3. WiFi / Driver        Status, Rebuild driver                ║\n'
        printf '    ║    [ ]  4. Storage              Disk usage, Erase macOS                ║\n'
        printf '    ║    [ ]  5. APT Sources          Enable, Disable updates                ║\n'
        printf '    ║    [ ]  6. Reboot               Reboot, Boot to macOS                  ║\n'
        printf '    ║    [ ]  7. Back to Main Menu                                     ║\n'
        printf '    ║%*s║\n' $((width + 1)) ''
        printf '    ╚%s╝\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        printf '\n'
        printf '    \033[2mKeys: SPACE Toggle  │  ENTER Execute\033[0m\n'
        printf '\n'
        printf '    > '

        local choice_num
        read -r choice_num < /dev/tty
        case "$choice_num" in
            1) echo "sysinfo" ;;
            2) echo "kernel" ;;
            3) echo "wifi" ;;
            4) echo "storage" ;;
            5) echo "apt" ;;
            6) echo "reboot" ;;
            7|"") echo "back" ;;
            *) echo "back" ;;
        esac
    else
        local choice
        choice=$(tui_menu "Manage Mode" "Select management operation:" \
            "System Info" "sysinfo" \
            "Kernel Management" "kernel" \
            "WiFi/Driver" "wifi" \
            "Storage" "storage" \
            "APT Sources" "apt" \
            "Reboot" "reboot" \
            "Back to Main Menu" "back") || return 1
        echo "$choice"
    fi
}

menu_system_info() {
    if command -v remote_get_info >/dev/null 2>&1 && \
       command -v remote_health_check >/dev/null 2>&1; then
        log_info "Retrieving system information..."
        local info
        info=$(remote_get_info)
        local health
        health=$(remote_health_check)
        tui_msgbox "System Information" "${info}\n\n---\n\nHealth Check:\n${health}"
    else
        tui_msgbox "Not Implemented" "Remote management functions not available.\n\nEnsure lib/remote.sh exists and provides:\n- remote_get_info\n- remote_health_check"
    fi
}

menu_kernel() {
    if [ "$TUI_BACKEND" = "raw" ]; then
        local width=76
        printf '\n'
        printf '    ╔%s╗\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        printf '    ║  \033[1mKERNEL MANAGEMENT\033[0m%*s║\n' $((width - 21)) ''
        printf '    ╠%s╣\n' "$(printf '═%.0s' $(seq 1 "$width"))"
        printf '    ║  \033[2mSelect multiple operations to execute:\033[0m%*s║\n' $((width - 48)) ''
        printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 "$width"))"
        printf '    ║  [ ]  Status             View current kernel and pin state          ║\n'
        printf '    ║  [ ]  Pin Kernel         Lock to current kernel, block updates     ║\n'
        printf '    ║  [ ]  Unpin Kernel      Allow kernel updates                      ║\n'
        printf '    ║  [ ]  Update Kernel     Full 7-phase kernel update (⚠ risky)     ║\n'
        printf '    ║  [ ]  Security Only     Non-kernel security patches only          ║\n'
        printf '    ╟%s╢\n' "$(printf '─%.0s' $(seq 1 "$width"))"
        printf '    ║  [ ]  Back              Return to management menu                 ║\n'
        printf '    ╚%s╝\n' "$(printf '─%.0s' $(seq 1 "$width"))"
        printf '\n'
        printf '    \033[2mKeys: SPACE Toggle  │  ENTER Execute  │  Q Cancel\033[0m\n'
        printf '\n'
        printf '    > '

        local choices
        read -r choices < /dev/tty
        if [ -z "$choices" ]; then
            return 1
        fi

        echo "$choices"
    else
        local choice
        choice=$(tui_menu "Kernel Management" "Select kernel operation:" \
            "Status" "status" \
            "Pin kernel" "pin" \
            "Unpin kernel" "unpin" \
            "Update kernel" "update" \
            "Security updates only" "security" \
            "Back" "back") || return 1

        echo "$choice"
    fi
}

run_kernel_operations() {
    local choices="$1"
    local num
    for num in $choices; do
        case "$num" in
            1)
                if command -v remote_kernel_status >/dev/null 2>&1; then
                    local status
                    status=$(remote_kernel_status)
                    tui_msgbox "Kernel Status" "$status"
                fi
                ;;
            2)
                if command -v remote_kernel_repin >/dev/null 2>&1; then
                    if tui_confirm "Pin Kernel" "This will pin the current kernel.\n\nProceed?"; then
                        remote_kernel_repin
                        tui_msgbox "Kernel Pinned" "Kernel has been pinned."
                    fi
                fi
                ;;
            3)
                if command -v remote_kernel_unpin >/dev/null 2>&1; then
                    if tui_confirm "Unpin Kernel" "This will unpin the kernel.\n\nProceed?"; then
                        remote_kernel_unpin
                        tui_msgbox "Kernel Unpinned" "Kernel has been unpinned."
                    fi
                fi
                ;;
            4)
                if tui_confirm "Update Kernel" "This will run the full kernel update process per AGENTS.md.\n\nThis is a complex operation with potential to brick the system if WiFi breaks.\n\nProceed?"; then
                    if command -v remote_kernel_update >/dev/null 2>&1; then
                        remote_kernel_update
                    fi
                fi
                ;;
            5)
                if tui_confirm "Security Updates" "This will apply security updates excluding kernel packages.\n\nProceed?"; then
                    if command -v remote_non_kernel_update >/dev/null 2>&1; then
                        remote_non_kernel_update
                    fi
                fi
                ;;
        esac
    done
}

kernel_handle_choice() {
    local choice="$1"

    case "$choice" in
        back|"") return 0 ;;
        *[![:space:]]*)
            for num in $choice; do
                case "$num" in
                    1) _kernel_status ;;
                    2) _kernel_pin ;;
                    3) _kernel_unpin ;;
                    4) _kernel_update ;;
                    5) _kernel_security ;;
                esac
            done
            ;;
    esac
}

_kernel_status() {
    if command -v remote_kernel_status >/dev/null 2>&1; then
        local status
        status=$(remote_kernel_status)
        tui_msgbox "Kernel Status" "$status"
    fi
}

_kernel_pin() {
    if command -v remote_kernel_repin >/dev/null 2>&1; then
        if tui_confirm "Pin Kernel" "This will pin the current kernel.\n\nProceed?"; then
            remote_kernel_repin
            tui_msgbox "Kernel Pinned" "Kernel has been pinned."
        fi
    fi
}

_kernel_unpin() {
    if command -v remote_kernel_unpin >/dev/null 2>&1; then
        if tui_confirm "Unpin Kernel" "This will unpin the kernel.\n\nProceed?"; then
            remote_kernel_unpin
            tui_msgbox "Kernel Unpinned" "Kernel has been unpinned."
        fi
    fi
}

_kernel_update() {
    if tui_confirm "Update Kernel" "This will run the full kernel update process.\n\nThis is risky - WiFi may break.\n\nProceed?"; then
        if command -v remote_kernel_update >/dev/null 2>&1; then
            remote_kernel_update
        fi
    fi
}

_kernel_security() {
    if tui_confirm "Security Updates" "Apply security patches (non-kernel).\n\nProceed?"; then
        if command -v remote_non_kernel_update >/dev/null 2>&1; then
            remote_non_kernel_update
            tui_msgbox "Updates Complete" "Security updates have been applied."
        else
            tui_msgbox "Not Implemented" "remote_non_kernel_update not available"
        fi
    fi
}

menu_wifi() {
    local choice
    choice=$(tui_menu "WiFi/Driver" "Select WiFi operation:" \
        "Status" "status" \
        "Rebuild driver" "rebuild" \
        "Back" "back") || return 1

    case "$choice" in
        status)
            if command -v remote_driver_status >/dev/null 2>&1; then
                local status
                status=$(remote_driver_status)
                tui_msgbox "WiFi/Driver Status" "$status"
            else
                tui_msgbox "Not Implemented" "remote_driver_status not available"
            fi
            ;;
        rebuild)
            if tui_confirm "Rebuild Driver" "This will rebuild the Broadcom WiFi driver via DKMS.\n\nProceed?"; then
                if command -v remote_driver_rebuild >/dev/null 2>&1; then
                    remote_driver_rebuild
                    tui_msgbox "Driver Rebuilt" "WiFi driver has been rebuilt."
                else
                    tui_msgbox "Not Implemented" "remote_driver_rebuild not available"
                fi
            fi
            ;;
    esac
}

menu_storage() {
    local choice
    choice=$(tui_menu "Storage" "Select storage operation:" \
        "Disk usage" "usage" \
        "Erase macOS and expand" "erase" \
        "Back" "back") || return 1

    case "$choice" in
        usage)
            if command -v remote_get_info >/dev/null 2>&1; then
                local usage
                usage=$(remote_get_info)
                tui_msgbox "Disk Usage" "$usage"
            else
                tui_msgbox "Not Implemented" "remote_get_info not available"
            fi
            ;;
        erase)
            if tui_confirm "ERASE macOS" "WARNING: This will DELETE all macOS partitions\nand expand Ubuntu to use the full disk.\n\nThis CANNOT be undone.\n\nProceed?"; then
                if command -v remote_erase_macos >/dev/null 2>&1; then
                    remote_erase_macos
                    tui_msgbox "macOS Erased" "macOS partitions have been removed and Ubuntu expanded."
                else
                    tui_msgbox "Not Implemented" "remote_erase_macos not available.\n\nSee AGENTS.md macOS Erasure section for manual steps."
                fi
            fi
            ;;
    esac
}

menu_apt() {
    local choice
    choice=$(tui_menu "APT Sources" "Select APT operation:" \
        "Enable sources" "enable" \
        "Disable sources" "disable" \
        "Back" "back") || return 1

    case "$choice" in
        enable)
            if command -v remote_apt_enable >/dev/null 2>&1; then
                remote_apt_enable
                tui_msgbox "APT Enabled" "APT sources have been enabled."
            else
                tui_msgbox "Not Implemented" "remote_apt_enable not available"
            fi
            ;;
        disable)
            if command -v remote_apt_disable >/dev/null 2>&1; then
                remote_apt_disable
                tui_msgbox "APT Disabled" "APT sources have been disabled."
            else
                tui_msgbox "Not Implemented" "remote_apt_disable not available"
            fi
            ;;
    esac
}

menu_reboot_remote() {
    if tui_confirm "Reboot" "This will reboot the remote Mac Pro.\n\nProceed?"; then
        if command -v remote_reboot >/dev/null 2>&1; then
            remote_reboot
            tui_msgbox "Reboot Initiated" "Reboot command sent to remote system."
        else
            tui_msgbox "Not Implemented" "remote_reboot not available"
        fi
    fi
}

run_manage_mode() {
    while true; do
        local choice
        choice=$(manage_menu) || break

        case "$choice" in
            sysinfo)   menu_system_info ;;
            kernel)    kernel_handle_choice "$(menu_kernel)" ;;
            wifi)      menu_wifi ;;
            storage)   menu_storage ;;
            apt)       menu_apt ;;
            reboot)    menu_reboot_remote ;;
            back|"")   break ;;
        esac
    done
}

# ── Legacy Menu Functions (for backward compatibility with lib modules) ──

select_deployment_method() {
    DEPLOY_METHOD=$(tui_menu "Select Deployment Method" "Choose how to deploy:" \
        "Internal partition (ESP)" "1" \
        "USB drive" "2" \
        "Full manual" "3" \
        "VM test (VirtualBox)" "4")
}

select_storage_layout() {
    STORAGE_LAYOUT=$(tui_menu "Select Storage Layout" "Choose partition scheme:" \
        "Dual-boot (preserve macOS)" "1" \
        "Full disk (replace macOS)" "2")
}

select_network_type() {
    NETWORK_TYPE=$(tui_menu "Select Network Type" "Choose network configuration:" \
        "WiFi only (Broadcom BCM4360)" "1" \
        "Ethernet available" "2")
}

confirm_settings() {
    local summary="Configuration summary:\n\n"
    case "$DEPLOY_METHOD" in
        1) summary+="Method: Internal partition (ESP)\n" ;;
        2) summary+="Method: USB drive\n" ;;
        3) summary+="Method: Full manual\n" ;;
        4) summary+="Method: VM test (VirtualBox)\n" ;;
    esac

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        case "$STORAGE_LAYOUT" in
            1) summary+="Storage: Dual-boot (preserve macOS)\n" ;;
            2) summary+="Storage: Full disk (replace macOS)\n" ;;
        esac
        case "$NETWORK_TYPE" in
            1) summary+="Network: WiFi only\n" ;;
            2) summary+="Network: Ethernet available\n" ;;
        esac
    fi

    summary+="\nProceed with deployment?"

    if ! tui_confirm "Confirm Settings" "$summary"; then
        exit 0
    fi
}

# ── Agent Mode ──

# Maps --operation names to remote.sh functions
_AGENT_OPERATIONS="sysinfo kernel_status kernel_pin kernel_unpin kernel_update "
_AGENT_OPERATIONS="${_AGENT_OPERATIONS}security_update health_check rollback_status "
_AGENT_OPERATIONS="${_AGENT_OPERATIONS}driver_status driver_rebuild disk_usage erase_macos "
_AGENT_OPERATIONS="${_AGENT_OPERATIONS}apt_enable apt_disable reboot boot_macos"

_validate_agent_deploy() {
    [ -z "${DEPLOY_METHOD:-}" ] && agent_error "Missing --method (1=ESP, 2=USB, 3=manual, 4=VM)" "$E_AGENT_PARAM"
    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        [ -z "${STORAGE_LAYOUT:-}" ] && agent_error "Missing --storage (1=dual-boot, 2=full-disk)" "$E_AGENT_PARAM"
        [ -z "${NETWORK_TYPE:-}" ] && agent_error "Missing --network (1=WiFi, 2=Ethernet)" "$E_AGENT_PARAM"
    fi
    case "$DEPLOY_METHOD" in
        1|2|3|4) ;;
        *) agent_error "Invalid --method: $DEPLOY_METHOD (must be 1-4)" "$E_USAGE" ;;
    esac
    if [ -n "${STORAGE_LAYOUT:-}" ]; then
        case "$STORAGE_LAYOUT" in
            1|2) ;;
            *) agent_error "Invalid --storage: $STORAGE_LAYOUT (must be 1 or 2)" "$E_USAGE" ;;
        esac
    fi
    if [ -n "${NETWORK_TYPE:-}" ]; then
        case "$NETWORK_TYPE" in
            1|2) ;;
            *) agent_error "Invalid --network: $NETWORK_TYPE (must be 1 or 2)" "$E_USAGE" ;;
        esac
    fi
}

_agent_deploy() {
    _validate_agent_deploy
    agent_output "settings" "Deploy Configuration" "" \
        "method" "$DEPLOY_METHOD" \
        "storage" "${STORAGE_LAYOUT:-N/A}" \
        "network" "${NETWORK_TYPE:-N/A}" \
        "wifiSsid" "${WIFI_SSID:-}" \
        "dryRun" "${DRY_RUN:-0}"

    local deploy_rc=0
    case "$DEPLOY_METHOD" in
        1) deploy_internal_partition || deploy_rc=$? ;;
        2) deploy_usb || deploy_rc=$? ;;
        3) deploy_manual || deploy_rc=$? ;;
        4) deploy_vm_test || deploy_rc=$? ;;
    esac

    if [ "$deploy_rc" -eq 0 ]; then
        agent_output "result" "Deploy" "success" "exitCode" "0"
        return 0
    else
        agent_output "result" "Deploy" "failed" "exitCode" "$deploy_rc"
        return "$deploy_rc"
    fi
}

_agent_manage() {
    local op="${REMOTE_OPERATION:-}"
    [ -z "$op" ] && agent_error "Missing --operation for manage mode. Available: $_AGENT_OPERATIONS" "$E_AGENT_PARAM"

    local host="${REMOTE_HOST:-macpro-linux}"

    case "$op" in
        sysinfo)         remote_get_info "$host" ;;
        kernel_status)   remote_kernel_status "$host" ;;
        kernel_pin)      remote_kernel_repin "$host" ;;
        kernel_unpin)    remote_kernel_unpin "$host" ;;
        kernel_update)   remote_kernel_update "$host" ;;
        security_update) remote_non_kernel_update "$host" ;;
        health_check)    remote_health_check "$host" ;;
        rollback_status)  remote_rollback_status "$host" ;;
        driver_status)   remote_driver_status "$host" ;;
        driver_rebuild)  remote_driver_rebuild "$host" ;;
        disk_usage)      remote_get_info "$host" ;;
        erase_macos)     remote_erase_macos "$host" ;;
        apt_enable)      remote_apt_enable "$host" ;;
        apt_disable)     remote_apt_disable "$host" ;;
        reboot)          remote_reboot "$host" ;;
        boot_macos)      remote_boot_macos "$host" ;;
        *) agent_error "Unknown operation: $op. Available: $_AGENT_OPERATIONS" "$E_USAGE" ;;
    esac
}

_agent_build_iso() {
    if [ ! -f "$LIB_DIR/build-iso.sh" ]; then
        agent_error "build-iso.sh not found in $LIB_DIR" "$E_CONFIG"
    fi
    agent_output "progress" "Build ISO" "starting"
    "$LIB_DIR/build-iso.sh"
    local rc=$?
    agent_output "result" "Build ISO" "$([ "$rc" -eq 0 ] && echo success || echo failed)" "exitCode" "$rc"
    return "$rc"
}

_agent_revert() {
    agent_output "progress" "Revert" "starting"
    if command -v rollback_from_journal >/dev/null 2>&1; then
        rollback_from_journal
    else
        revert_changes
    fi
    agent_output "result" "Revert" "complete"
}

run_agent_mode() {
    log_info "Agent mode activated (JSON=$JSON_OUTPUT, YES=$CONFIRM_YES)"

    # Determine what to do from CLI flags
    if [ -n "${REMOTE_OPERATION:-}" ]; then
        # Manage mode
        _agent_manage
    elif [ -n "${DEPLOY_METHOD:-}" ]; then
        # Deploy mode
        _agent_deploy
    elif [ "${DRY_RUN:-0}" -eq 1 ] && [ -z "${DEPLOY_METHOD:-}" ]; then
        # Dry-run without method — run full deploy dry-run
        DEPLOY_METHOD="${DEPLOY_METHOD:-1}"
        STORAGE_LAYOUT="${STORAGE_LAYOUT:-1}"
        NETWORK_TYPE="${NETWORK_TYPE:-1}"
        agent_output "settings" "Dry-Run Deploy (defaults)" "" \
            "method" "$DEPLOY_METHOD" \
            "storage" "$STORAGE_LAYOUT" \
            "network" "$NETWORK_TYPE"
        _agent_deploy
    else
        # No operation specified — output available operations and exit
        agent_output "error" "No Operation" \
            "Specify --method for deploy, --operation for manage, or --revert" \
            "availableDeployMethods" "1,2,3,4" \
            "availableManageOperations" "$_AGENT_OPERATIONS"
        return "$E_AGENT_PARAM"
    fi
}

# ── Environment Exploration ──
explore_environment() {
    local default_ip
    default_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ipconfig getifaddr en2 2>/dev/null || echo "127.0.0.1")
    
    local ip_address
    ip_address=$(tui_input "IP Address" "Enter the IP address of this Mac Pro:" "$default_ip")
    [ -z "$ip_address" ] && ip_address="$default_ip"
    
    local sip_status
    sip_status=$(csrutil status 2>/dev/null | grep -o 'enabled\|disabled' | head -1 || echo "unknown")
    sip_status=$(echo "$sip_status" | tr '[:lower:]' '[:upper:]')
    
    local boot_device
    boot_device=$(bless --info --getboot 2>/dev/null | head -1 || echo "Unable to determine")
    
    local startup_disk
    startup_disk=$(systemsetup -getstartupdisk 2>/dev/null | awk -F': ' '{print $2}' || echo "Unable to determine")
    
    local disk_info
    disk_info=$(df -h /)
    
    local part_info
    part_info=$(diskutil list 2>/dev/null || echo "Unable to read partition map")
    
    local refind_status="Not found"
    [ -d "/Volumes/EFI/EFI/refind" ] || [ -d "/EFI/refind" ] && refind_status="Detected"
    
    local info
    info="=== System Information ===
Mac Pro IP Address: $ip_address

macOS Version: $(sw_vers -productName) $(sw_vers -productVersion)
Build: $(sw_vers -buildVersion)

SIP Status: $sip_status

=== Bootloader Information ===
rEFInd: $refind_status
Current Boot Device (bless): $boot_device
Startup Disk (systemsetup): $startup_disk

=== Disk Space ===
$disk_info

=== Partition Map ===
$part_info"
    
    tui_msgbox "Environment Exploration Results" "$info"
}

# ── Main Entry Point ──
main() {
    # Check for root/sudo — deployment operations require elevated privileges
    # Initialize logging
    log_init

    # Set up error handling traps
    if ! command -v cleanup_on_error >/dev/null 2>&1; then
        cleanup_on_error() { true; }
    fi
    trap 'cleanup_on_error' EXIT
    trap 'cleanup_on_error; exit 130' SIGINT
    trap 'cleanup_on_error; exit 143' SIGTERM

    log_info "Ubuntify v0.2.57 starting..."
    log_info "Log file: $(log_get_file_path)"
    log_info "TUI backend: $TUI_BACKEND"

    if [ "$TUI_BACKEND" = "raw" ]; then
        tui_ascii_header "Mac Pro Conversion and Management Tool"
    fi

     mkdir -p "${OUTPUT_DIR:-$HOME/.Ubuntu_Deployment}"

     # _USING_EXAMPLE_CONF tracks whether user has a real config (CONF_FILE is redirected to example at source time)
     if [ "${AGENT_MODE:-0}" -ne 1 ] && [ "${_USING_EXAMPLE_CONF:-0}" -eq 1 ]; then
         if ! tui_confirm "No existing configuration found." "Configure a new device?"; then
             exit 0
         fi
         # Explore current environment to gather system information
         explore_environment
         # User confirmed they want to configure a new device - get deployment options first
         if ! menu_deploy; then
             exit 0
         fi
         # Now gather configuration details for the selected deployment
         if ! prompt_config; then
             die "Missing required configuration"
         fi
         # Run the selected deployment method
         local deploy_rc=0
         case "$DEPLOY_METHOD" in
             1) deploy_internal_partition || deploy_rc=$? ;;
             2) deploy_usb || deploy_rc=$? ;;
             3) deploy_manual || deploy_rc=$? ;;
             4) deploy_vm_test || deploy_rc=$? ;;
         esac
         exit "$deploy_rc"
     fi

     decrypt_config "$CONF_FILE"

     if [ "${AGENT_MODE:-0}" -ne 1 ]; then
         if [ "$(id -u)" -ne 0 ]; then
             die "This script must be run as root (use sudo)."
         fi
     fi

     # Skip prompt_config for agent remote operations (--operation) - no local config needed.
     # Required for agent deploy (--method) and all TTY mode operations.
     local _needs_config=1
     if [ "${AGENT_MODE:-0}" -eq 1 ] && [ -n "${REMOTE_OPERATION:-}" ]; then
         _needs_config=0
     fi
     if [ "$_needs_config" -eq 1 ] && ! prompt_config; then
         die "Missing required configuration — check deploy.conf or provide values via CLI flags"
     fi

     if [ "${AGENT_MODE:-0}" -eq 1 ]; then
         run_agent_mode
         local agent_rc=$?
         log_shutdown
         exit "$agent_rc"
     fi

    while true; do
        local mode
        mode=$(select_mode)

        case "$mode" in
            deploy)
                run_deploy_mode
                ;;
            manage)
                run_manage_mode
                ;;
            revert)
                if command -v handle_revert_flag >/dev/null 2>&1; then
                    handle_revert_flag "--revert"
                else
                    error "Revert module not loaded"
                fi
                ;;
            exit)
                log_info "Exiting..."
                break
                ;;
        esac
    done

    log_shutdown
}

main "$@"
