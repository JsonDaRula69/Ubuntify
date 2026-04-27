#!/bin/bash
set -e
set -o pipefail
set -u
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

# CLI flags
DRY_RUN=0
VERBOSE=0
AGENT_MODE=0
_REVERT_REQUESTED=0
CONFIRM_YES=0
JSON_OUTPUT=0
REMOTE_HOST=""
REMOTE_OPERATION=""

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ESP_NAME="CIDATA"
readonly ESP_SIZE="5g"

# Derive version from git tags (falls back to "dev" if not in a git repo or no tags)
APP_VERSION="$(cd "$SCRIPT_DIR" && git describe --tags 2>/dev/null | sed 's/^v//' || echo "dev")"
readonly APP_VERSION
export APP_VERSION

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
source "$LIB_DIR/remote_mac.sh"
source "$LIB_DIR/discover.sh"

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
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/.Ubuntify}"
OUTPUT_DIR_INITIAL="$OUTPUT_DIR"
CONF_FILE="${OUTPUT_DIR}/deploy.conf"
# Track whether config was loaded from user's deploy.conf or the example template
_USING_EXAMPLE_CONF=0
if [ ! -f "$CONF_FILE" ]; then
    warn "deploy.conf not found — using defaults from deploy.conf.example"
    _USING_EXAMPLE_CONF=1
    mkdir -p "$OUTPUT_DIR"
    cp "${LIB_DIR}/deploy.conf.example" "$CONF_FILE"
    chmod 600 "$CONF_FILE"
fi

# Default values for config keys
USERNAME=""
REALNAME=""
PASSWORD_HASH=""
HOSTNAME=""
SSH_KEYS=""
SSH_KEYS_FILE=""
ENCRYPTION="plaintext"
DEPLOY_MODE="remote"
TARGET_HOST=""
REMOTE_SUDO_PASSWORD=""
WHURL=""

# --- Input Validation ---
# Validate user-facing config fields against their respective standards.
# Returns 0 if all valid, 1 if any fail (with error messages logged).

validate_username() {
    # Linux username: 1-32 chars, lowercase alphanumeric + underscore + hyphen,
    # must start with letter or underscore. No spaces.
    # Ref: useradd(8), Debian policy
    local val="$1"
    if [ ${#val} -lt 1 ] || [ ${#val} -gt 32 ]; then
        log_error "USERNAME must be 1-32 characters (got ${#val})"
        return 1
    fi
    if ! echo "$val" | grep -qE '^[a-z_][a-z0-9_-]*$'; then
        log_error "USERNAME must start with a lowercase letter or underscore and contain only lowercase letters, digits, hyphens, and underscores (got: '$val')"
        return 1
    fi
    return 0
}

validate_hostname() {
    # RFC 952/1123 hostname: 1-63 chars, alphanumeric + dots + hyphens,
    # must start/end with alphanumeric, no consecutive dots.
    # Also allow single-word hostnames (no dots) for local network names.
    local val="$1"
    if [ ${#val} -lt 1 ] || [ ${#val} -gt 63 ]; then
        log_error "HOSTNAME must be 1-63 characters (got ${#val})"
        return 1
    fi
    # Must not start or end with hyphen or dot
    case "$val" in
        -*) log_error "HOSTNAME must not start with a hyphen (got: '$val')"; return 1 ;;
        .*) log_error "HOSTNAME must not start with a dot (got: '$val')"; return 1 ;;
        *-) log_error "HOSTNAME must not end with a hyphen (got: '$val')"; return 1 ;;
        *.) log_error "HOSTNAME must not end with a dot (got: '$val')"; return 1 ;;
    esac
    # Only lowercase alphanumeric, hyphens, and dots
    if ! echo "$val" | grep -qE '^[a-z0-9][a-z0-9.-]*[a-z0-9]$|^[a-z0-9]$'; then
        log_error "HOSTNAME must contain only lowercase letters, digits, hyphens, and dots (got: '$val')"
        return 1
    fi
    # No consecutive dots
    if echo "$val" | grep -q '\.\.'; then
        log_error "HOSTNAME must not contain consecutive dots (got: '$val')"
        return 1
    fi
    return 0
}

validate_realname() {
    # GECOS field: printable ASCII, no colon (field separator in /etc/passwd)
    local val="$1"
    if [ -z "$val" ]; then
        return 0  # REALNAME can be empty (defaults to USERNAME)
    fi
    if echo "$val" | grep -q ':'; then
        log_error "REALNAME must not contain colons (GECOS field separator in /etc/passwd)"
        return 1
    fi
    # Reject newlines and tabs (non-visible in GECOS)
    case "$val" in
        *$'\n'*) log_error "REALNAME must not contain newlines"; return 1 ;;
    esac
    return 0
}

validate_wifi_ssid() {
    # WiFi SSID: 1-32 bytes, no null bytes, printable characters
    local val="$1"
    if [ ${#val} -lt 1 ] || [ ${#val} -gt 32 ]; then
        log_error "WIFI_SSID must be 1-32 characters (got ${#val})"
        return 1
    fi
    # Reject newlines (break YAML structure)
    case "$val" in
        *$'\n'*) log_error "WIFI_SSID must not contain newlines"; return 1 ;;
    esac
    return 0
}

validate_wifi_password() {
    # WiFi password: 8-63 chars for WPA2/3 PSK (Passphrase), or 64 hex chars for raw key
    local val="$1"
    if [ ${#val} -eq 64 ] && echo "$val" | grep -qE '^[0-9a-fA-F]{64}$'; then
        # Valid 64-char hex key
        return 0
    fi
    if [ ${#val} -lt 8 ] || [ ${#val} -gt 63 ]; then
        log_error "WIFI_PASSWORD must be 8-63 characters (WPA passphrase) or 64 hex characters (WPA raw key, got ${#val} chars)"
        return 1
    fi
    return 0
}

validate_inputs() {
    local errors=0

    if [ -z "${TARGET_HOST:-}" ]; then
        log_error "TARGET_HOST is required (remote-only mode)"
        errors=$((errors + 1))
    fi

    if ! validate_username "${USERNAME:-}"; then
        errors=$((errors + 1))
    fi
    if ! validate_hostname "${HOSTNAME:-}"; then
        errors=$((errors + 1))
    fi
    if ! validate_realname "${REALNAME:-}"; then
        errors=$((errors + 1))
    fi
    if [ "${NETWORK_TYPE:-1}" = "1" ] || [ "${NETWORK_TYPE:-}" = "wifi" ]; then
        if ! validate_wifi_ssid "${WIFI_SSID:-}"; then
            errors=$((errors + 1))
        fi
        if ! validate_wifi_password "${WIFI_PASSWORD:-}"; then
            errors=$((errors + 1))
        fi
    fi

    if ! validate_username "$USERNAME"; then
        errors=$((errors + 1))
    fi
    if ! validate_hostname "$HOSTNAME"; then
        errors=$((errors + 1))
    fi
    if ! validate_realname "$REALNAME"; then
        errors=$((errors + 1))
    fi
    if [ "$NETWORK_TYPE" = "1" ] || [ "$NETWORK_TYPE" = "wifi" ]; then
        if ! validate_wifi_ssid "$WIFI_SSID"; then
            errors=$((errors + 1))
        fi
        if ! validate_wifi_password "$WIFI_PASSWORD"; then
            errors=$((errors + 1))
        fi
    fi

    if [ "$errors" -gt 0 ]; then
        return 1
    fi
    return 0
}

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
            # Deployment mode
            DEPLOY_MODE)    DEPLOY_MODE="$value" ;;
            TARGET_HOST)    TARGET_HOST="$value" ;;
            REMOTE_SUDO_PASSWORD) REMOTE_SUDO_PASSWORD="$value" ;;
            MACOS_SIZE_MODE) MACOS_SIZE_MODE="$value" ;;
            MACOS_SIZE_GB)  MACOS_SIZE_GB="$value" ;;
            # Output directory
            OUTPUT_DIR)     OUTPUT_DIR="${value:-$HOME/.Ubuntify}" ;;
            *)              warn "Unknown config key: $key" ;;
        esac
    done < "$conf"
}
parse_conf "$CONF_FILE" || die "Failed to load $CONF_FILE"

# When using the example template, strip __REPLACE__ placeholder values
# so prompt_config() correctly sees them as empty and prompts the user
if [ "$_USING_EXAMPLE_CONF" -eq 1 ]; then
    for var in USERNAME REALNAME PASSWORD_HASH HOSTNAME TARGET_HOST REMOTE_SUDO_PASSWORD WIFI_SSID WIFI_PASSWORD; do
        case "${!var}" in
            __REPLACE__|'') eval "$var=\"\"" ;;
        esac
    done
    case "$SSH_KEYS" in
        *__REPLACE__*) SSH_KEYS="" ;;
    esac
fi

# Re-resolve CONF_FILE if OUTPUT_DIR was set in config (different from initial)
if [ "$OUTPUT_DIR" != "${OUTPUT_DIR_INITIAL:-}" ] && [ -f "$OUTPUT_DIR/deploy.conf" ]; then
    CONF_FILE="$OUTPUT_DIR/deploy.conf"
fi

mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"
_owner="${SUDO_USER:-$USER}"
if [ "$_owner" != "$USER" ] || [ "$(id -u)" -eq 0 ]; then
    chown "$_owner" "$OUTPUT_DIR" 2>/dev/null || true
fi

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
export MACOS_SIZE_MODE=""
export MACOS_SIZE_GB=""

generate_password_hash() {
    local password="$1"
    openssl passwd -6 "$password" 2>/dev/null
}

prompt_config() {
    local missing=0

    if [ "$AGENT_MODE" -eq 1 ]; then
        [ -z "$USERNAME" ] && { agent_error "USERNAME required in deploy.conf or --agent mode"; missing=1; }
        [ -z "$HOSTNAME" ] && { agent_error "HOSTNAME required in deploy.conf or --agent mode"; missing=1; }
        [ -z "$PASSWORD_HASH" ] && { agent_error "PASSWORD_HASH required in deploy.conf or --agent mode"; missing=1; }
        [ -z "$SSH_KEYS" ] && [ -z "$SSH_KEYS_FILE" ] && { agent_error "SSH_KEY or SSH_KEYS_FILE required in deploy.conf"; missing=1; }
        [ -z "$WIFI_SSID" ] && { agent_error "WIFI_SSID required in deploy.conf or --agent mode"; missing=1; }
        [ -z "$WIFI_PASSWORD" ] && { agent_error "WIFI_PASSWORD required in deploy.conf or --agent mode"; missing=1; }
        [ -z "$WEBHOOK_HOST" ] && WEBHOOK_HOST="localhost"
        [ "$missing" -eq 1 ] && return 1
        return 0
    fi

    _prompt_username
    _prompt_realname
    _prompt_password
    _prompt_ssh_keys
    _prompt_wifi_ssid
    _prompt_wifi_password
    _prompt_webhook
    _prompt_hostname
    prompt_deploy_mode
    prompt_encryption_mode
    configure_ssh_config

    _show_config_menu
}

_show_config_menu() {
    while true; do
        local ssh_key_display="0 key(s)"
        if [ -n "$SSH_KEYS" ]; then
            local ssh_key_count=0
            while IFS= read -r key; do
                [ -n "$key" ] && ssh_key_count=$((ssh_key_count + 1))
            done <<EOF
$SSH_KEYS
EOF
            ssh_key_display="$ssh_key_count key(s)"
        fi
        local pass_display="(set)"
        [ -z "$PASSWORD_HASH" ] && pass_display="(not set)"
        local sudo_pass_display="(set)"
        [ -z "$REMOTE_SUDO_PASSWORD" ] && sudo_pass_display="(not set)"
        local wifi_pass_display="(set)"
        [ -z "$WIFI_PASSWORD" ] && wifi_pass_display="(not set)"

        local sudo_pass_display="(set)"
        [ -z "$REMOTE_SUDO_PASSWORD" ] && sudo_pass_display="(not set)"

        tui_menu "Configuration" "Review and edit settings:" \
            "Username:        $USERNAME" "username" \
            "Full Name:       ${REALNAME:-(not set)}" "realname" \
            "Password:        $pass_display" "password" \
            "Sudo Password:   $sudo_pass_display" "sudo_password" \
            "SSH Keys:        $ssh_key_display" "ssh" \
            "WiFi SSID:       ${WIFI_SSID:-(not set)}" "wifi_ssid" \
            "WiFi Password:   $wifi_pass_display" "wifi_password" \
            "Webhook:         ${WEBHOOK_HOST}:${WEBHOOK_PORT}" "webhook" \
            "Hostname:        ${HOSTNAME:-(not set)}" "hostname" \
            "Target Host:     ${TARGET_HOST:-(not set)}" "target_host" \
            "Encryption:      ${ENCRYPTION:-plaintext}" "encryption" \
            "▸ Done — proceed" "done" || return 1
        local choice="$_TUI_RESULT"

        case "$choice" in
            username)      _prompt_username ;;
            realname)      _prompt_realname ;;
            password)      _prompt_password ;;
            sudo_password) _prompt_sudo_password ;;
            ssh)           _prompt_ssh_keys ;;
            wifi_ssid)     _prompt_wifi_ssid ;;
            wifi_password) _prompt_wifi_password ;;
            webhook)       _prompt_webhook ;;
            hostname)      _prompt_hostname ;;
            target_host)
                _DEPLOY_MODE_PROMPTED=0
                prompt_deploy_mode
                ;;
            encryption)    prompt_encryption_mode ;;
            done)          break ;;
        esac
    done

    WHURL="http://${WEBHOOK_HOST}:${WEBHOOK_PORT}/webhook"
    export USERNAME REALNAME PASSWORD_HASH HOSTNAME SSH_KEYS SSH_KEYS_FILE
    export WIFI_SSID WIFI_PASSWORD WEBHOOK_HOST WEBHOOK_PORT WHURL
    export DEPLOY_MODE TARGET_HOST REMOTE_SUDO_PASSWORD
    return 0
}

_prompt_username() {
    while true; do
        tui_input "Username" "Enter username for the Ubuntu system (lowercase letters, digits, hyphens, underscores):" "${USERNAME:-}"
        USERNAME="$_TUI_RESULT"
        if [ -z "$USERNAME" ]; then
            tui_msgbox "Username Required" "A username is required for the Ubuntu system.\n\nPress Enter to try again."
            continue
        fi
        if validate_username "$USERNAME"; then
            save_config_key "USERNAME" "$USERNAME"
            break
        else
            tui_msgbox "Invalid Username" "Username must start with a lowercase letter or underscore and contain only lowercase letters, digits, hyphens, and underscores.\n\nGot: '$USERNAME'\n\nPress Enter to try again."
            USERNAME=""
        fi
    done
}

_prompt_realname() {
    tui_input "Full Name" "Enter full name (GECOS, press Enter to use username):" "${REALNAME:-}"
    REALNAME="$_TUI_RESULT"
    [ -z "$REALNAME" ] && REALNAME="$USERNAME"
    save_config_key "REALNAME" "$REALNAME"
}

_prompt_password() {
    local password password2
    if [ -n "$PASSWORD_HASH" ]; then
        tui_menu "Password" "Ubuntu password is set (hashed).\n\nWhat would you like to do?" \
            "Change password" "change" \
            "Keep current password" "keep" || return 0
        [ "$_TUI_RESULT" = "keep" ] && return 0
    fi
    while true; do
        tui_password "Password" "Enter password for $USERNAME:"
        password="$_TUI_RESULT"
        [ -z "$password" ] && { tui_msgbox "Password Required" "A password is required.\n\nPress Enter to try again."; continue; }
        tui_password "Confirm Password" "Confirm password:"
        password2="$_TUI_RESULT"
        if [ "$password" != "$password2" ]; then
            tui_msgbox "Passwords Do Not Match" "The passwords you entered do not match.\n\nPress Enter to try again."
            continue
        fi
        break
    done
}

_prompt_sudo_password() {
    if [ -n "$REMOTE_SUDO_PASSWORD" ]; then
        local host_display="${TARGET_HOST:-macpro}"
        tui_menu "Remote Sudo Password" "Current sudo password for $host_display is set.\n\nWhat would you like to do?" \
            "Show current password" "show" \
            "Change password" "change" \
            "Keep current password" "keep" || return 0
        case "$_TUI_RESULT" in
            show)
                tui_msgbox "Remote Sudo Password" "Current sudo password for $host_display:\n\n$REMOTE_SUDO_PASSWORD"
                return 0
                ;;
            keep) return 0 ;;
        esac
    fi
    while true; do
        tui_password "Remote Sudo Password" "Enter sudo password for $TARGET_HOST:"
        REMOTE_SUDO_PASSWORD="$_TUI_RESULT"
        if [ -z "$REMOTE_SUDO_PASSWORD" ]; then
            tui_msgbox "Password Required" "A sudo password is required for remote operations.\n\nPress Enter to try again."
            continue
        fi
        log_info "Verifying sudo access on $TARGET_HOST..."
        if remote_mac_sudo echo "sudo ok" >/dev/null 2>&1; then
            save_config_key "REMOTE_SUDO_PASSWORD" "$REMOTE_SUDO_PASSWORD"
            tui_msgbox "Sudo Verified" "Sudo password accepted for $TARGET_HOST."
            break
        else
            tui_msgbox "Sudo Password Failed" "The sudo password for $TARGET_HOST was not accepted.\n\nPress Enter to try again."
            REMOTE_SUDO_PASSWORD=""
        fi
    done
}

_prompt_ssh_keys() {
    if [ -n "$SSH_KEYS" ] || [ -n "$SSH_KEYS_FILE" ]; then
        log_info "SSH keys already configured from deploy.conf (${#SSH_KEYS} bytes)"
        tui_confirm "SSH Keys" "SSH keys are already configured.\n\nKeep existing keys?"
        if [ "$?" -eq 0 ]; then
            return 0
        fi
    fi
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
                tui_input "SSH Public Key" "Paste your SSH public key:" ""
                manual_key="$_TUI_RESULT"
                if [ -n "$manual_key" ]; then
                    SSH_KEYS="$manual_key"
                    save_config_key "SSH_KEY" "$SSH_KEYS"
                fi
            elif [ -n "$selected_key" ]; then
                SSH_KEYS="$selected_key"
                save_config_key "SSH_KEY" "$SSH_KEYS"
            fi
            ;;
        generate)
            local generated_key
            generated_key=$(prompt_generate_key)
            if [ -n "$generated_key" ]; then
                SSH_KEYS="$generated_key"
                save_config_key "SSH_KEY" "$SSH_KEYS"
            fi
            ;;
        skip)
            warn "No SSH keys configured. You will need console access to the Mac Pro."
            ;;
    esac
}

_prompt_wifi_ssid() {
    while true; do
        tui_input "WiFi SSID" "Enter WiFi network name:" "${WIFI_SSID:-}"
        WIFI_SSID="$_TUI_RESULT"
        if [ -z "$WIFI_SSID" ]; then
            tui_msgbox "WiFi SSID Required" "A WiFi network name is required.\n\nPress Enter to try again."
            continue
        fi
        save_config_key "WIFI_SSID" "$WIFI_SSID"
        break
    done
}

_prompt_wifi_password() {
    if [ -n "$WIFI_PASSWORD" ]; then
        tui_menu "WiFi Password" "Current WiFi password is set.\n\nWhat would you like to do?" \
            "Show current password" "show" \
            "Change password" "change" \
            "Keep current password" "keep" || return 0
        case "$_TUI_RESULT" in
            show)
                tui_msgbox "WiFi Password" "Current WiFi password:\n\n$WIFI_PASSWORD"
                return 0
                ;;
            keep) return 0 ;;
        esac
    fi
    while true; do
        tui_password "WiFi Password" "Enter WiFi password:"
        WIFI_PASSWORD="$_TUI_RESULT"
        if [ -z "$WIFI_PASSWORD" ]; then
            tui_msgbox "WiFi Password Required" "A WiFi password is required.\n\nPress Enter to try again."
            continue
        fi
        save_config_key "WIFI_PASSWORD" "$WIFI_PASSWORD"
        break
    done
}

_prompt_webhook() {
    local webhook_default="localhost"
    local detected_ip
    detected_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ipconfig getifaddr en2 2>/dev/null || echo "")
    [ -n "$detected_ip" ] && webhook_default="$detected_ip"
    tui_input "Webhook Host" "Enter monitoring host IP (webhook server):" "${WEBHOOK_HOST:-$webhook_default}"
    WEBHOOK_HOST="$_TUI_RESULT"
    [ -z "$WEBHOOK_HOST" ] && WEBHOOK_HOST="$webhook_default"
    save_config_key "WEBHOOK_HOST" "$WEBHOOK_HOST"

    tui_input "Webhook Port" "Enter webhook port:" "${WEBHOOK_PORT:-8080}"
    WEBHOOK_PORT="$_TUI_RESULT"
    [ -z "$WEBHOOK_PORT" ] && WEBHOOK_PORT="8080"
    save_config_key "WEBHOOK_PORT" "$WEBHOOK_PORT"
}

_prompt_hostname() {
    while true; do
        tui_input "Hostname" "Enter hostname for the Ubuntu system (lowercase letters, digits, hyphens, dots):" "${HOSTNAME:-}"
        HOSTNAME="$_TUI_RESULT"
        if [ -z "$HOSTNAME" ]; then
            tui_msgbox "Hostname Required" "A hostname is required for the Ubuntu system.\n\nPress Enter to try again."
            continue
        fi
        if validate_hostname "$HOSTNAME"; then
            save_config_key "HOSTNAME" "$HOSTNAME"
            break
        else
            tui_msgbox "Invalid Hostname" "Hostname must be 1-63 characters, start/end with a letter or digit, and contain only lowercase letters, digits, hyphens, and dots.\n\nGot: '$HOSTNAME'\n\nPress Enter to try again."
            HOSTNAME=""
        fi
    done
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

    # Build menu items using array for tui_menu (no eval needed)
    # tui_menu takes pairs: "Display Text" "tag_value"
    local -a menu_args=("SSH Public Key" "Select SSH public key to use:")
    local idx=1
    local IFS_OLD="$IFS"
    IFS='|'
    for label in $key_labels; do
        menu_args+=("${label}" "${idx}")
        idx=$((idx + 1))
    done
    IFS="$IFS_OLD"
    menu_args+=("Paste key manually..." "manual" "Skip SSH keys" "skip")

    local selection
    tui_menu "${menu_args[@]}" || return 1
    selection="$_TUI_RESULT"

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
    tui_menu "SSH Key Configuration" "Choose how to provide SSH public key:" \
        "Provide existing key" "existing" \
        "Generate new key" "generate" \
            "Skip SSH setup" "skip" || return 1
    choice="$_TUI_RESULT"
    echo "$choice"
}

prompt_generate_key() {
    local key_type_choice
    tui_menu "Generate SSH Key" "Select key type:" \
        "ed25519 (recommended)" "ed25519" \
            "rsa (4096-bit)" "rsa" || return 1
    key_type_choice="$_TUI_RESULT"

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
        tui_input "macOS Host IP" "Enter macOS IP address (or leave empty to skip):" ""
        macpro_ip="$_TUI_RESULT"
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
    summary="${summary}Username:    ${USERNAME:-(not set)}\n"
    summary="${summary}Hostname:    ${HOSTNAME:-(not set)}\n"
    summary="${summary}Real Name:   ${REALNAME:-(not set)}\n"
    summary="${summary}WiFi SSID:   ${WIFI_SSID:-(not set)}\n"
    summary="${summary}Webhook:     ${WEBHOOK_HOST:-(not set)}:${WEBHOOK_PORT:-8080}\n"
    summary="${summary}SSH Keys:    ${ssh_key_count} key(s)\n"
    summary="${summary}\n"
    summary="${summary}Target Host:      ${TARGET_HOST:-macpro}\n"
    summary="${summary}Deployment Method: ${method_name}\n"
    summary="${summary}Storage Layout:      ${storage_name}\n"
    if [ "${STORAGE_LAYOUT:-1}" = "1" ]; then
        local split_desc="auto"
        case "${MACOS_SIZE_MODE:-auto}" in
            max_linux) split_desc="Max Linux (min macOS)" ;;
            max_macos) split_desc="Max macOS (min Ubuntu)" ;;
            custom)   split_desc="Custom (macOS: ${MACOS_SIZE_GB:-?}GB)" ;;
            *)        split_desc="Auto" ;;
        esac
        summary="${summary}Disk Split:          ${split_desc}\n"
    fi
    summary="${summary}Network Type:        ${network_name}\n"
    summary="${summary}\n"
    summary="${summary}Proceed with deployment?"

    tui_confirm "Confirm Configuration" "$summary"
}

_conf_escape() {
    printf '%s' "$1" | awk '{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); print}'
}

save_config_key() {
    local key="$1"
    local value="$2"
    local conf="${3:-$CONF_FILE}"
    [ ! -f "$conf" ] && return 1
    local escaped_value
    escaped_value="$(_conf_escape "$value")"
    if grep -q "^${key}=" "$conf" 2>/dev/null; then
        local tmpfile
        tmpfile=$(mktemp)
        awk -v k="$key" -v v="$escaped_value" '
            $0 ~ "^" k "=" { print k "=\"" v "\""; next }
            { print }
        ' "$conf" > "$tmpfile" && mv "$tmpfile" "$conf"
    else
        printf '%s="%s"\n' "$key" "$escaped_value" >> "$conf"
    fi
}

is_config_valid() {
    if [ -z "${USERNAME:-}" ] || [ "$USERNAME" = "__REPLACE__" ]; then return 1; fi
    if [ -z "${HOSTNAME:-}" ] || [ "$HOSTNAME" = "__REPLACE__" ]; then return 1; fi
    if [ -z "${TARGET_HOST:-}" ] || [ "$TARGET_HOST" = "__REPLACE__" ]; then return 1; fi
    if [ -z "${PASSWORD_HASH:-}" ] || [ "$PASSWORD_HASH" = "__REPLACE__" ]; then return 1; fi
    if { [ -z "${WIFI_SSID:-}" ] || [ "$WIFI_SSID" = "__REPLACE__" ]; } && [ "${NETWORK_TYPE:-1}" = "1" ]; then return 1; fi
    return 0
}

handle_existing_config() {
    decrypt_config "$CONF_FILE"
    parse_conf "$CONF_FILE"
    if is_config_valid; then
        if [ "${AGENT_MODE:-0}" -eq 1 ]; then
            log_info "Valid config found, loading"
            _CONFIG_LOADED=1
            return 0
        fi
        tui_menu "Configuration Found" \
            "A valid deploy.conf was found." \
            "Load existing configuration" "load" \
            "Overwrite (create new)" "overwrite" \
            "Delete and exit" "delete" || return 1
        local choice="$_TUI_RESULT"
        case "$choice" in
            load)
                log_info "Loading existing configuration"
                _CONFIG_LOADED=1
                return 0
                ;;
            overwrite)
                rm -f "$CONF_FILE"
                cp "${LIB_DIR}/deploy.conf.example" "$CONF_FILE"
                chmod 600 "$CONF_FILE"
                ;;
            delete)
                rm -f "$CONF_FILE"
                log_info "Config deleted, exiting"
                exit 0
                ;;
        esac
    else
        if [ "${AGENT_MODE:-0}" -eq 1 ]; then
            log_warn "Existing config is invalid"
            return 1
        fi
        tui_msgbox "Invalid Config" \
            "The existing deploy.conf is incomplete or invalid.\n\nYou will be guided through creating a new configuration."
        rm -f "$CONF_FILE"
        cp "${LIB_DIR}/deploy.conf.example" "$CONF_FILE"
        chmod 600 "$CONF_FILE"
    fi
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
        printf 'DEPLOY_MODE="%s"\n' "$(_conf_escape "$DEPLOY_MODE")"
        printf 'TARGET_HOST="%s"\n' "$(_conf_escape "$TARGET_HOST")"
        printf 'REMOTE_SUDO_PASSWORD="%s"\n' "$(_conf_escape "$REMOTE_SUDO_PASSWORD")"
        printf 'MACOS_SIZE_MODE="%s"\n' "$(_conf_escape "${MACOS_SIZE_MODE:-}")"
        printf 'MACOS_SIZE_GB="%s"\n' "$(_conf_escape "${MACOS_SIZE_GB:-}")"
        printf 'OUTPUT_DIR="%s"\n' "$(_conf_escape "$OUTPUT_DIR")"
    } >> "$conf"
    chmod 600 "$conf"

    local _owner="${SUDO_USER:-$USER}"
    if [ "$_owner" != "$USER" ] || [ "$(id -u)" -eq 0 ]; then
        chown "$_owner" "$conf" 2>/dev/null || true
    fi

    if [ "$ENCRYPTION" != "plaintext" ]; then
        encrypt_config "$conf"
    fi
}

prompt_deploy_mode() {
    [ "${_DEPLOY_MODE_PROMPTED:-0}" -eq 1 ] && return 0
    log_info "prompt_deploy_mode: prompting for target host"

    DEPLOY_MODE="remote"
    save_config_key "DEPLOY_MODE" "remote"

    if [ -z "${TARGET_HOST:-}" ] || [ "${TARGET_HOST:-}" = "__REPLACE__" ]; then
        while true; do
            local discovered_hosts
            discovered_hosts="$(detect_remote_hosts)" || true

            if [ -n "$discovered_hosts" ]; then
                local host_count
                host_count=$(echo "$discovered_hosts" | wc -l | tr -d ' ')
                log_info "Found $host_count SSH service(s) via Bonjour"

                local menu_args=("Target Host" "Select the Mac Pro or enter manually:")
                local host_line=1
                while IFS= read -r discovered; do
                    [ -z "$discovered" ] && continue
                    menu_args+=("$discovered (SSH service)")
                    menu_args+=("$discovered")
                    host_line=$((host_line + 1))
                done <<< "$discovered_hosts"
                menu_args+=("Manual entry" "manual")

                local selection
                tui_menu "${menu_args[@]}" || return 1
                selection="$_TUI_RESULT"

                if [ "$selection" = "manual" ]; then
                    tui_input "Target Host" \
                        "Enter SSH hostname or IP for the Mac Pro (macOS):" "" || return 1
                    TARGET_HOST="$_TUI_RESULT"
                else
                    TARGET_HOST="$selection"
                fi
            else
                tui_input "Target Host" \
                    "Enter SSH hostname or IP for the Mac Pro (macOS):" "" || return 1
                TARGET_HOST="$_TUI_RESULT"
            fi

    if [ -z "${TARGET_HOST:-}" ]; then
                tui_msgbox "Target Host Required" "An SSH hostname or IP is required for remote deployment.\n\nPress Enter to try again."
                continue
            fi
            save_config_key "TARGET_HOST" "$TARGET_HOST"
            break
        done
    fi

    local resolved_host
    resolved_host="$(resolve_hostname "$TARGET_HOST")"
    local resolve_rc=$?
    if [ "$resolved_host" != "$TARGET_HOST" ]; then
        log_info "Hostname resolved: $TARGET_HOST -> $resolved_host"
        if [ "$AGENT_MODE" -ne 1 ]; then
            tui_msgbox "Host Resolved" "Hostname resolved:\n\n  $TARGET_HOST -> $resolved_host\n\nUsing $resolved_host for SSH connection."
        else
            agent_output "info" "Host Resolved" "$TARGET_HOST -> $resolved_host"
        fi
        TARGET_HOST="$resolved_host"
        save_config_key "TARGET_HOST" "$TARGET_HOST"
    elif [ $resolve_rc -ne 0 ]; then
        if [ "$AGENT_MODE" -eq 1 ]; then
            log_warn "Could not verify SSH connectivity to $TARGET_HOST via any hostname format"
            agent_output "warning" "SSH Connectivity" "Could not verify SSH connectivity to $TARGET_HOST"
        else
            local ssh_resolved=0
            while [ "$ssh_resolved" -eq 0 ]; do
                local retry_choice
                tui_menu "SSH Connection Failed" \
                    "Cannot connect to $TARGET_HOST via SSH.\n\nChoose an option:" \
                    "Try $TARGET_HOST.local" "local" \
                    "Try $TARGET_HOST.lan" "lan" \
                    "Enter different hostname" "manual" \
                    "Abort" "abort" || { retry_choice="abort"; }
                retry_choice="$_TUI_RESULT"

                case "$retry_choice" in
                    local)
                        TARGET_HOST="${TARGET_HOST%%.*}.local"
                        save_config_key "TARGET_HOST" "$TARGET_HOST"
                        if remote_mac_test; then
                            ssh_resolved=1
                            tui_msgbox "Connected" "Successfully connected to $TARGET_HOST"
                        fi
                        ;;
                    lan)
                        TARGET_HOST="${TARGET_HOST%%.*}.lan"
                        save_config_key "TARGET_HOST" "$TARGET_HOST"
                        if remote_mac_test; then
                            ssh_resolved=1
                            tui_msgbox "Connected" "Successfully connected to $TARGET_HOST"
                        fi
                        ;;
                    manual)
                        tui_input "Target Host" \
                            "Enter SSH hostname or IP for the Mac Pro (macOS):" "" || continue
                        TARGET_HOST="$_TUI_RESULT"
                        resolved_host="$(resolve_hostname "$TARGET_HOST")"
                        if [ "$resolved_host" != "$TARGET_HOST" ]; then
                            TARGET_HOST="$resolved_host"
                        fi
                        save_config_key "TARGET_HOST" "$TARGET_HOST"
                        if remote_mac_test; then
                            ssh_resolved=1
                            tui_msgbox "Connected" "Successfully connected to $TARGET_HOST"
                        fi
                        ;;
                    abort|*)
                        return 1
                        ;;
                esac
            done
        fi
    fi

    if [ "$AGENT_MODE" -ne 1 ]; then
        if ! remote_mac_test; then
            warn "Cannot connect to $TARGET_HOST via SSH. Ensure SSH is enabled and key authentication is set up."
        fi
    fi

    if [ "$AGENT_MODE" -ne 1 ]; then
        local remote_sudo_warning
        remote_sudo_warning="The remote sudo password will be stored in deploy.conf (encrypted if"
        remote_sudo_warning="${remote_sudo_warning} encryption is enabled).\n\nFor security, backup your Mac Pro, use a dedicated user account,"
        remote_sudo_warning="${remote_sudo_warning} and remove any sensitive data."
        tui_msgbox "Security Notice" "$remote_sudo_warning"

        while true; do
            if [ -z "$REMOTE_SUDO_PASSWORD" ]; then
                tui_password "Remote Sudo Password" \
                    "Enter sudo password for $TARGET_HOST:" || return 1
                REMOTE_SUDO_PASSWORD="$_TUI_RESULT"
            fi

            log_info "Verifying sudo access on $TARGET_HOST..."
            if remote_mac_sudo echo "sudo ok" >/dev/null 2>&1; then
                log_info "Sudo access on $TARGET_HOST: OK"
                save_config_key "REMOTE_SUDO_PASSWORD" "$REMOTE_SUDO_PASSWORD"
                break
            else
                tui_msgbox "Sudo Password Failed" "The sudo password for $TARGET_HOST was not accepted.\n\nPlease try again."
                REMOTE_SUDO_PASSWORD=""
            fi
        done
    fi

    _DEPLOY_MODE_PROMPTED=1
}

prompt_encryption_mode() {
    if [ -n "$ENCRYPTION" ] && [ "$ENCRYPTION" != "plaintext" ]; then
        return 0
    fi

    local choice
    tui_menu "Password Encryption" \
        "How should the password be stored in deploy.conf?" \
        "Plaintext (file chmod 600)" "plaintext" \
        "AES-256 (encrypted, password required to decrypt)" "aes256" \
            "macOS Keychain (stored in Keychain, config file cleaned)" "keychain" || return 0
    choice="$_TUI_RESULT"

    ENCRYPTION="$choice"
    save_config_key "ENCRYPTION" "$ENCRYPTION"
    export ENCRYPTION
}

encrypt_config() {
    local conf="${1:-$CONF_FILE}"
    case "$ENCRYPTION" in
        plaintext)
            chmod 600 "$conf"
            _owner="${SUDO_USER:-$USER}"
            [ "$(id -u)" -eq 0 ] && chown "$_owner" "$conf" 2>/dev/null || true
            ;;
        aes256)
            if [ "${AGENT_MODE:-0}" -eq 1 ]; then
                log "Agent mode: skipping config encryption (no interactive TTY for password prompt)"
                chmod 600 "$conf"
                _owner="${SUDO_USER:-$USER}"
                [ "$(id -u)" -eq 0 ] && chown "$_owner" "$conf" 2>/dev/null || true
                return 0
            fi
            local enc_file="${conf}.enc"
            openssl enc -aes-256-cbc -pbkdf2 -salt -in "$conf" -out "$enc_file" || die "Failed to encrypt config"
            rm -f "$conf"
            chmod 600 "$enc_file"
            _owner="${SUDO_USER:-$USER}"
            [ "$(id -u)" -eq 0 ] && chown "$_owner" "$enc_file" 2>/dev/null || true
            log "Config encrypted to ${enc_file} (plaintext config removed)"
            ;;
        keychain)
            if [ "$(uname)" != "Darwin" ]; then
                die "Keychain encryption only available on macOS"
            fi
            security add-generic-password -a "macpro-deploy" -s "macpro-deploy-conf" -w "$(cat "$conf")" -U 2>/dev/null || \
                die "Failed to store config in macOS Keychain"
            rm -f "$conf"
            log "Config stored in macOS Keychain (plaintext config removed)"
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
        if [ "${AGENT_MODE:-0}" -eq 1 ]; then
            log "Agent mode: skipping config decryption (no interactive TTY for password prompt)"
            return 0
        fi
        openssl enc -aes-256-cbc -pbkdf2 -d -in "$enc_file" -out "$conf" || die "Failed to decrypt config"
        chmod 600 "$conf"
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

    local _owner="${SUDO_USER:-$USER}"
    if [ "$_owner" != "$USER" ] || [ "$(id -u)" -eq 0 ]; then
        chown "$_owner" "$conf" 2>/dev/null || true
    fi
}

show_help() {
    echo "Usage: sudo ./prepare-deployment.sh [OPTIONS]"
    echo ""
    echo "Ubuntify - Mac Pro Conversion Tool v${APP_VERSION}"
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
    echo "  --encryption MODE     Password storage: plaintext, aes256, keychain (default: plaintext)"
    echo "  --target-host HOST    Mac Pro SSH hostname/IP (e.g., macpro)"
    echo "  --remote-password PWD Remote sudo password (Warning: visible in ps; prefer deploy.conf)"
    echo "  --username USER       Override username from deploy.conf"
    echo "  --hostname HOST       Override hostname from deploy.conf"
    echo "  --vm                  Use VM test mode (autoinstall-vm.yaml)"
    echo "  --output-dir DIR      Override runtime output directory (default: ~/.Ubuntify/)"
    echo ""
    echo "Modes:"
    echo "  Deploy   - Build ISO, deploy to Mac Pro via SSH"
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
        --macos-size)        MACOS_SIZE_MODE="$2"; shift 2 ;;
        --macos-size=*)      MACOS_SIZE_MODE="${1#*=}"; shift ;;
        --macos-gb)          MACOS_SIZE_GB="$2"; shift 2 ;;
        --macos-gb=*)        MACOS_SIZE_GB="${1#*=}"; shift ;;
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
        --encryption)        ENCRYPTION="$2"; shift 2 ;;
        --encryption=*)        ENCRYPTION="${1#*=}"; shift ;;
        --deploy-mode)          : ;; # ignored — remote-only mode
        --deploy-mode=*)       : ;; # ignored — remote-only mode
        --target-host)          TARGET_HOST="$2"; shift 2 ;;
        --target-host=*)        TARGET_HOST="${1#*=}"; shift ;;
        --remote-password)      REMOTE_SUDO_PASSWORD="$2"; shift 2 ;;
        --remote-password=*)    REMOTE_SUDO_PASSWORD="${1#*=}"; shift ;;
        --username)            USERNAME="$2"; shift 2 ;;
        --username=*)        USERNAME="${1#*=}"; shift ;;
        --hostname)          HOSTNAME="$2"; shift 2 ;;
        --hostname=*)        HOSTNAME="${1#*=}"; shift ;;
        --vm)                DEPLOY_METHOD=4; shift ;;
        --output-dir)        OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*)      OUTPUT_DIR="${1#*=}"; shift ;;
        --revert)            _REVERT_REQUESTED=1; shift ;;
        --help|-h)           show_help ;;
        *)                   echo "Unknown option: $1"; show_help ;;
    esac
done

if [ "$VERBOSE" -eq 1 ]; then
    LOG_LEVEL="$LOG_LEVEL_DEBUG"
fi

# ── Mode Selection ──

select_mode() {
    tui_menu "Ubuntify ${APP_VERSION}" "Select operation:" \
        "Deploy Ubuntu" "deploy" \
        "Manage System (Kernel · WiFi · Storage · Updates)" "manage" \
        "Revert Failed Deploy" "revert" \
        "Exit" "exit" || { echo "exit"; return; }
    echo "$_TUI_RESULT"
}

# ── Deploy Mode Sub-menus ──

deploy_menu() {
    local choice
    tui_menu "Deploy Mode" "Select deployment operation:" \
        "Build ISO" "build_iso" \
        "Deploy" "deploy" \
        "Monitor" "monitor" \
        "Test in VM" "test_vm" \
        "Revert" "revert" \
            "Back to Main Menu" "back" || return 1
    choice="$_TUI_RESULT"
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
        tui_msgbox "Build Complete" "ISO built successfully.\n\nOutput: ${OUTPUT_DIR}/ubuntu-macpro.iso"
    fi
}

menu_deploy_select() {
    local method
    tui_menu "Select Deployment Method" "Choose how to deploy Ubuntu:" \
        "Internal partition (ESP)" "1" \
        "USB drive" "2" \
        "Full manual" "3" \
        "VM test (VirtualBox)" "4" \
            "Cancel" "cancel" || return 1
    method="$_TUI_RESULT"

    if [ "$method" = "cancel" ]; then
        return 1
    fi

    DEPLOY_METHOD="$method"

    local storage=""
    local network=""

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        tui_menu "Select Storage Layout" "Choose partition scheme:" \
            "Dual-boot (preserve macOS)" "1" \
            "Full disk (replace macOS)" "2" \
                    "Cancel" "cancel" || return 1
        storage="$_TUI_RESULT"
        [ "$storage" = "cancel" ] && return 1
        STORAGE_LAYOUT="$storage"

        if [ "$STORAGE_LAYOUT" = "1" ]; then
            tui_menu "Disk Space Allocation" "How should disk space be split between macOS and Ubuntu?" \
                "Max Linux (min macOS)" "max_linux" \
                "Max macOS (min Ubuntu)" "max_macos" \
                "Custom sizes" "custom" \
                "Cancel" "cancel" || return 1
            local split_choice="$_TUI_RESULT"
            [ "$split_choice" = "cancel" ] && return 1
            MACOS_SIZE_MODE="$split_choice"

            if [ "$MACOS_SIZE_MODE" = "custom" ]; then
                local macos_gb=""
                while true; do
                    tui_input "macOS Partition Size" "Enter size for macOS partition (GB, min 50):" ""
                    macos_gb="$_TUI_RESULT"
                    if [ -z "$macos_gb" ] || ! echo "$macos_gb" | grep -qE '^[0-9]+$'; then
                        tui_msgbox "Invalid Size" "Please enter a positive whole number in GB."
                        continue
                    fi
                    if [ "$macos_gb" -lt 50 ]; then
                        tui_msgbox "Too Small" "macOS needs at least 50GB to function.\n\nYou entered: ${macos_gb}GB"
                        continue
                    fi
                    MACOS_SIZE_GB="$macos_gb"
                    break
                done
                save_config_key "MACOS_SIZE_GB" "$MACOS_SIZE_GB"
                tui_msgbox "Custom Partition" "macOS: ${MACOS_SIZE_GB}GB\nUbuntu: remaining disk space"
            elif [ "$MACOS_SIZE_MODE" = "max_linux" ]; then
                MACOS_SIZE_GB=""
                tui_msgbox "Max Linux" "macOS will be shrunk to minimum (~50GB).\nUbuntu gets the remaining disk space."
            else
                MACOS_SIZE_GB="max_macos"
                tui_msgbox "Max macOS" "macOS keeps its current size plus margin.\nUbuntu gets ~40GB (minimum viable install)."
            fi
            save_config_key "MACOS_SIZE_MODE" "$MACOS_SIZE_MODE"
        fi

        tui_menu "Select Network Type" "Choose network configuration:" \
            "WiFi only (Broadcom BCM4360)" "1" \
            "Ethernet available" "2" \
                    "Cancel" "cancel" || return 1
        network="$_TUI_RESULT"
        [ "$network" = "cancel" ] && return 1
        NETWORK_TYPE="$network"
    fi
}

_run_deploy_method() {
    local deploy_rc=0
    case "$DEPLOY_METHOD" in
        1) deploy_internal_partition || deploy_rc=$? ;;
        2) deploy_usb || deploy_rc=$? ;;
        3) deploy_manual || deploy_rc=$? ;;
        4) deploy_vm_test || deploy_rc=$? ;;
    esac
    return "$deploy_rc"
}

menu_deploy() {
    if ! menu_deploy_select; then
        return 1
    fi

    if ! show_pre_execution_summary "$STORAGE_LAYOUT" "$NETWORK_TYPE"; then
        return 1
    fi

    log_info "Starting deployment with method $DEPLOY_METHOD..."
    _DEPLOY_STARTED=1
    local deploy_rc=0
    _run_deploy_method || deploy_rc=$?

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
    tui_menu "Monitor" "Select monitor action:" \
        "Start monitor" "start" \
        "View logs" "logs" \
        "Stop monitor" "stop" \
            "Back" "back" || return 1
    choice="$_TUI_RESULT"

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
    tui_menu "VM Test" "Select VM test action:" \
        "Build VM ISO" "build" \
        "Create VM" "create" \
        "Run VM" "run" \
        "SSH to VM" "ssh" \
        "Stop VM" "stop" \
        "View serial log" "serial" \
            "Back" "back" || return 1
    choice="$_TUI_RESULT"

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
    tui_menu "Mac Pro Management" "Select operation:" \
        "System Info (kernel · WiFi · disk · DKMS)" "sysinfo" \
        "Kernel Management (status, pin, update)" "kernel" \
        "WiFi / Driver (status, rebuild)" "wifi" \
        "Storage (disk usage, erase macOS)" "storage" \
        "APT Sources (enable, disable)" "apt" \
        "Reboot (reboot, boot to macOS)" "reboot" \
        "Back to Main Menu" "back" || { echo "back"; return; }
    echo "$_TUI_RESULT"
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
    tui_checklist "Kernel Management" "Select operations:" \
        "Status" "1" "View current kernel and pin state" off \
        "Pin Kernel" "2" "Lock to current kernel, block updates" off \
        "Unpin Kernel" "3" "Allow kernel updates" off \
        "Update Kernel" "4" "Full 7-phase kernel update (risky)" off \
        "Security Only" "5" "Non-kernel security patches only" off || return 1
    echo "$_TUI_RESULT"
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
    tui_menu "WiFi/Driver" "Select WiFi operation:" \
        "Status" "status" \
        "Rebuild driver" "rebuild" \
            "Back" "back" || return 1
    choice="$_TUI_RESULT"

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
        back) return 0 ;;
    esac
}

menu_storage() {
    local choice
    tui_menu "Storage" "Select storage operation:" \
        "Disk usage" "usage" \
        "Erase macOS and expand" "erase" \
            "Back" "back" || return 1
    choice="$_TUI_RESULT"

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
        back) return 0 ;;
    esac
}

menu_apt() {
    local choice
    tui_menu "APT Sources" "Select APT operation:" \
        "Enable sources" "enable" \
        "Disable sources" "disable" \
            "Back" "back" || return 1
    choice="$_TUI_RESULT"

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
        back) return 0 ;;
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
            headless)  remote_headless_verify ;;
            reboot)    menu_reboot_remote ;;
            back|"")   break ;;
        esac
    done
}

# ── Agent Mode ──

# Maps --operation names to remote.sh functions
_AGENT_OPERATIONS="sysinfo kernel_status kernel_pin kernel_unpin kernel_update "
_AGENT_OPERATIONS="${_AGENT_OPERATIONS}security_update health_check rollback_status "
_AGENT_OPERATIONS="${_AGENT_OPERATIONS}driver_status driver_rebuild disk_usage erase_macos "
_AGENT_OPERATIONS="${_AGENT_OPERATIONS}apt_enable apt_disable reboot boot_macos headless_verify"

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
    if [ -z "${TARGET_HOST:-}" ]; then
        agent_error "Missing --target-host (required for remote deployment)" "$E_AGENT_PARAM"
    fi
}

_agent_deploy() {
    _validate_agent_deploy
    _DEPLOY_STARTED=1
    agent_output "settings" "Deploy Configuration" "" \
        "method" "$DEPLOY_METHOD" \
        "storage" "${STORAGE_LAYOUT:-N/A}" \
        "network" "${NETWORK_TYPE:-N/A}" \
        "deployMode" "remote" \
        "targetHost" "${TARGET_HOST:-N/A}" \
        "wifiSsid" "${WIFI_SSID:-}" \
        "dryRun" "${DRY_RUN:-0}"

    if ! remote_mac_preflight; then
        agent_error "Remote preflight checks failed for ${TARGET_HOST:-macpro}" "$E_CHECK"
            return 1
        fi

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
        headless_verify) remote_headless_verify "$host" ;;
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
    elif [ "${_REVERT_REQUESTED:-0}" -eq 1 ]; then
        # Revert mode via agent
        _agent_revert
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
    local sip_status
    sip_status=$(remote_mac_exec "csrutil status 2>/dev/null | grep -o 'enabled\\|disabled' | head -1 || echo unknown")
    sip_status=$(echo "$sip_status" | tr '[:lower:]' '[:upper:]')

    local boot_device
    boot_device=$(remote_mac_exec "bless --info --getboot 2>/dev/null | head -1 || echo 'Unable to determine'")

    local startup_disk
    startup_disk=$(remote_mac_exec "systemsetup -getstartupdisk" 2>/dev/null | awk -F': ' '{print $2}' || echo "Unable to determine")

    local disk_info
    disk_info=$(remote_mac_exec "df -h /")

    local part_info
    part_info=$(remote_mac_exec "diskutil list 2>/dev/null || echo 'Unable to read partition map'")

    local refind_status="Not found"
    remote_mac_exec "test -d /Volumes/EFI/EFI/refind -o -d /EFI/refind" 2>/dev/null && refind_status="Detected"

    local macos_name
    macos_name=$(remote_mac_exec "sw_vers -productName")
    local macos_ver
    macos_ver=$(remote_mac_exec "sw_vers -productVersion")
    local macos_build
    macos_build=$(remote_mac_exec "sw_vers -buildVersion")

    local info
    info="=== System Information (Remote: ${TARGET_HOST:-macpro}) ===

macOS Version: ${macos_name} ${macos_ver}
Build: ${macos_build}

SIP Status: ${sip_status}

=== Bootloader Information ===
rEFInd: ${refind_status}
Current Boot Device (bless): ${boot_device}
Startup Disk (systemsetup): ${startup_disk}

=== Disk Space ===
${disk_info}

=== Partition Map ===
${part_info}"

    tui_msgbox "Environment Exploration (Remote: ${TARGET_HOST:-macpro})" "$info"
}

_CONFIG_CLEANUP_DONE=0
_DEPLOY_STARTED=0
cleanup_config_on_exit() {
    [ "$_CONFIG_CLEANUP_DONE" -eq 1 ] && return 0
    _CONFIG_CLEANUP_DONE=1
    if [ -f "$CONF_FILE" ]; then
        # If deployment was attempted, always keep the config
        if [ "${_DEPLOY_STARTED:-0}" -eq 1 ]; then
            log_info "Deployment was attempted — keeping config at $CONF_FILE"
            return 0
        fi
        parse_conf "$CONF_FILE" 2>/dev/null || true
        if ! is_config_valid; then
            log_info "Incomplete config detected, removing $CONF_FILE"
            rm -f "$CONF_FILE"
        elif [ "${AGENT_MODE:-0}" -ne 1 ]; then
            if tui_confirm "Keep Configuration?" \
                "A valid deploy.conf exists.\n\nKeep it for future use?"; then
                log_info "Keeping config at $CONF_FILE"
            else
                rm -f "$CONF_FILE"
                log_info "Config deleted per user request"
            fi
        fi
    fi
}

# ── Main Entry Point ──
main() {
    log_init

    if ! command -v cleanup_on_error >/dev/null 2>&1; then
        cleanup_on_error() { true; }
    fi
    trap 'cleanup_on_error; cleanup_config_on_exit' EXIT
    trap 'cleanup_on_error; cleanup_config_on_exit; exit 130' SIGINT
    trap 'cleanup_on_error; cleanup_config_on_exit; exit 143' SIGTERM

    log_info "Ubuntify v${APP_VERSION} starting..."
    log_info "Log file: $(log_get_file_path)"

    SPLASH_STEP_COUNT=3
    _tui_set_default_terminal_size
    tui_splash_init "Mac Pro Conversion and Management Tool v${APP_VERSION}"


    tui_splash_step "Verifying dependencies"
    check_dependencies
    log_info "Dependencies verified"
    tui_splash_step_done "Verifying dependencies"

    tui_splash_step "Preparing output directory"
    mkdir -p "${OUTPUT_DIR}"
    _owner="${SUDO_USER:-$USER}"
    if [ "$_owner" != "$USER" ] || [ "$(id -u)" -eq 0 ]; then
        chown "$_owner" "${OUTPUT_DIR}" 2>/dev/null || true
    fi
    tui_splash_step_done "Preparing output directory"

    tui_splash_hold

    # Handle --revert: defer from argument parsing to ensure logging/traps are active
    if [ "${_REVERT_REQUESTED:-0}" -eq 1 ]; then
        handle_revert_flag "--revert"
        exit $?
    fi

    if [ -f "$CONF_FILE" ] && [ "${_USING_EXAMPLE_CONF:-0}" -ne 1 ]; then
        if ! handle_existing_config; then
            die "Configuration setup cancelled"
        fi
    elif [ ! -f "$CONF_FILE" ]; then
        # Should not happen (copied at boot), but just in case
        mkdir -p "$(dirname "$CONF_FILE")"
        cp "${LIB_DIR}/deploy.conf.example" "$CONF_FILE"
        chmod 600 "$CONF_FILE"
        local _owner="${SUDO_USER:-$USER}"
        [ "$(id -u)" -eq 0 ] && chown "$_owner" "$CONF_FILE" 2>/dev/null || true
    fi

    decrypt_config "$CONF_FILE"

    # Root check: remote mode doesn't need local root
    local _needs_root=0
    if [ "${AGENT_MODE:-0}" -eq 1 ] && [ -z "${REMOTE_OPERATION:-}" ]; then
        _needs_root=1
    fi
    if [ "$_needs_root" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
        die "Deployment requires root (use sudo)."
    fi

    # Skip prompt_config for agent remote operations (--operation) - no local config needed.
    # Required for agent deploy (--method) and all TTY mode operations.
    local _needs_config=1
    if [ "${AGENT_MODE:-0}" -eq 1 ] && [ -n "${REMOTE_OPERATION:-}" ]; then
        _needs_config=0
    fi
    if [ "$_needs_config" -eq 1 ] && [ "${_CONFIG_LOADED:-0}" -ne 1 ] && ! prompt_config; then
        die "Missing required configuration — check deploy.conf or provide values via CLI flags"
    fi
    if [ "$_needs_config" -eq 1 ] && ! validate_inputs; then
        die "Invalid configuration — see errors above"
    fi

    if ! remote_mac_preflight; then
        die "Remote preflight checks failed for ${TARGET_HOST:-macpro}. See errors above."
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
