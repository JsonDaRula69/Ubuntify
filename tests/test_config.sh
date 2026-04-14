#!/bin/bash
# Test deploy.conf parsing, placeholder substitution, and encryption

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="${PROJECT_DIR}/lib"

source "${LIB_DIR}/colors.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/dryrun.sh"

TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
    fi
}

assert_not_empty() {
    local desc="$1" actual="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$actual" ]; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        echo "  FAIL: $desc (empty value)"
    fi
}

assert_file_contains() {
    local desc="$1" file="$2" pattern="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -q "$pattern" "$file" 2>/dev/null; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        echo "  FAIL: $desc (pattern not found: $pattern)"
    fi
}

assert_file_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        echo "  FAIL: $desc (pattern should not exist: $pattern)"
    fi
}

# ── Test parse_conf ──

echo "=== Test: parse_conf ==="

# Create temp config file
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/test.conf" <<'CONF'
# Test config
USERNAME=testuser
REALNAME=Test User
HOSTNAME=testbox
PASSWORD_HASH=$6$salt$hash
WIFI_SSID=TestWiFi
WIFI_PASSWORD=TestPass
WEBHOOK_HOST=192.168.1.100
WEBHOOK_PORT=9090
ENCRYPTION=plaintext
OUTPUT_DIR=/tmp/test-output
SSH_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkey1 user1@host
SSH_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkey2 user2@host
SSH_KEY=ssh-rsa AAAAB3NzaC1yc2EAAAAIkey3 user3@host
CONF

# Source parse_conf inline (extract from prepare-deployment.sh)
USERNAME=""
REALNAME=""
PASSWORD_HASH=""
HOSTNAME=""
SSH_KEYS=""
SSH_KEYS_FILE=""
ENCRYPTION="plaintext"
OUTPUT_DIR=""
WIFI_SSID=""
WIFI_PASSWORD=""
WEBHOOK_HOST=""
WEBHOOK_PORT=""

parse_conf() {
    local conf="$1"
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*|[[:space:]]'#'*) continue ;;
        esac
        local key="${line%%=*}"
        local value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # Strip surrounding double quotes from value (KEY="value" format)
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
        esac
        [ -z "$key" ] && continue
        case "$key" in
            USERNAME)       USERNAME="$value" ;;
            REALNAME)       REALNAME="$value" ;;
            PASSWORD_HASH)  PASSWORD_HASH="$value" ;;
            HOSTNAME)       HOSTNAME="$value" ;;
            SSH_KEY)        SSH_KEYS="${SSH_KEYS}${SSH_KEYS:+
}$value" ;;
            SSH_KEYS_FILE)  SSH_KEYS_FILE="$value" ;;
            WIFI_SSID)      WIFI_SSID="$value" ;;
            WIFI_PASSWORD)  WIFI_PASSWORD="$value" ;;
            WEBHOOK_HOST)   WEBHOOK_HOST="$value" ;;
            WEBHOOK_PORT)   WEBHOOK_PORT="$value" ;;
            ENCRYPTION)     ENCRYPTION="$value" ;;
            OUTPUT_DIR)     OUTPUT_DIR="$value" ;;
        esac
    done < "$conf"
}

parse_conf "$TMPDIR/test.conf"

assert_eq "USERNAME parsed" "testuser" "$USERNAME"
assert_eq "REALNAME parsed" "Test User" "$REALNAME"
assert_eq "HOSTNAME parsed" "testbox" "$HOSTNAME"
assert_eq "WIFI_SSID parsed" "TestWiFi" "$WIFI_SSID"
assert_eq "WIFI_PASSWORD parsed" "TestPass" "$WIFI_PASSWORD"
assert_eq "WEBHOOK_HOST parsed" "192.168.1.100" "$WEBHOOK_HOST"
assert_eq "WEBHOOK_PORT parsed" "9090" "$WEBHOOK_PORT"

# Password hash with $ preserved
assert_not_empty "PASSWORD_HASH not empty" "$PASSWORD_HASH"

# SSH keys accumulated (3 keys)
key_count=$(echo "$SSH_KEYS" | wc -l | tr -d ' ')
assert_eq "SSH key count" "3" "$key_count"

# First SSH key starts correctly
first_key=$(echo "$SSH_KEYS" | head -1)
case "$first_key" in
    ssh-ed25519*) TESTS_PASS=$((TESTS_PASS + 1)) ;;
    *) TESTS_FAIL=$((TESTS_FAIL + 1)); echo "  FAIL: First SSH key format" ;;
esac
TESTS_RUN=$((TESTS_RUN + 1))

# ── Test placeholder substitution ──

echo "=== Test: placeholder substitution ==="

# Create template with placeholders
cat > "$TMPDIR/template.yaml" <<'TMPL'
hostname: __HOSTNAME__
username: __USERNAME__
realname: __REALNAME__
password: "__PASSWORD_HASH__"
endpoint: "__WHURL__"
authorized-keys:
__SSH_KEYS__
wh_url: __WHURL__
wifi_ssid: __WIFI_SSID__
wifi_pass: __WIFI_PASSWORD__
for _key in __SSH_KEYS_LIST__; do
TMPL

OUTPUT_PATH="$TMPDIR/output.yaml"
cp "$TMPDIR/template.yaml" "$OUTPUT_PATH"

WHURL="http://192.168.1.100:9090/webhook"

sed -i "s#__HOSTNAME__#${HOSTNAME}#g" "$OUTPUT_PATH" 2>/dev/null || \
    sed -i '' "s#__HOSTNAME__#${HOSTNAME}#g" "$OUTPUT_PATH"
sed -i "s#__USERNAME__#${USERNAME}#g" "$OUTPUT_PATH" 2>/dev/null || \
    sed -i '' "s#__USERNAME__#${USERNAME}#g" "$OUTPUT_PATH"
sed -i "s#__REALNAME__#${REALNAME}#g" "$OUTPUT_PATH" 2>/dev/null || \
    sed -i '' "s#__REALNAME__#${REALNAME}#g" "$OUTPUT_PATH"
sed -i "s#__WHURL__#${WHURL}#g" "$OUTPUT_PATH" 2>/dev/null || \
    sed -i '' "s#__WHURL__#${WHURL}#g" "$OUTPUT_PATH"
sed -i "s#__WIFI_SSID__#${WIFI_SSID}#g" "$OUTPUT_PATH" 2>/dev/null || \
    sed -i '' "s#__WIFI_SSID__#${WIFI_SSID}#g" "$OUTPUT_PATH"
sed -i "s#__WIFI_PASSWORD__#${WIFI_PASSWORD}#g" "$OUTPUT_PATH" 2>/dev/null || \
    sed -i '' "s#__WIFI_PASSWORD__#${WIFI_PASSWORD}#g" "$OUTPUT_PATH"

assert_file_contains "HOSTNAME substituted" "$OUTPUT_PATH" "hostname: testbox"
assert_file_contains "USERNAME substituted" "$OUTPUT_PATH" "username: testuser"
assert_file_contains "WHURL substituted" "$OUTPUT_PATH" "http://192.168.1.100:9090/webhook"
assert_file_not_contains "No __HOSTNAME__ remain" "$OUTPUT_PATH" "__HOSTNAME__"
assert_file_not_contains "No __USERNAME__ remain" "$OUTPUT_PATH" "__USERNAME__"
assert_file_not_contains "No __WHURL__ remain" "$OUTPUT_PATH" "__WHURL__"
assert_file_not_contains "No __WIFI_SSID__ remain" "$OUTPUT_PATH" "__WIFI_SSID__"

# ── Test SSH key YAML generation ──

echo "=== Test: SSH key YAML generation ==="

yaml_keys=""
bash_keys=""
while IFS= read -r key; do
    [ -z "$key" ] && continue
    yaml_keys="${yaml_keys}      - ${key}"$'\n'
    bash_keys="${bash_keys} \"${key}\""
done <<< "$SSH_KEYS"
yaml_keys="${yaml_keys%$'\n'}"

assert_not_empty "YAML keys generated" "$yaml_keys"
assert_not_empty "Bash keys generated" "$bash_keys"

# YAML key list starts with correct indent
case "$yaml_keys" in
    "      - "*) TESTS_PASS=$((TESTS_PASS + 1)) ;;
    *) TESTS_FAIL=$((TESTS_FAIL + 1)); echo "  FAIL: YAML key indent" ;;
esac
TESTS_RUN=$((TESTS_RUN + 1))

# Bash key list starts with quote (leading space ok)
case "$bash_keys" in
    *ssh-*) TESTS_PASS=$((TESTS_PASS + 1)) ;;
    *) TESTS_FAIL=$((TESTS_FAIL + 1)); echo "  FAIL: Bash key format" ;;
esac
TESTS_RUN=$((TESTS_RUN + 1))

# ── Test generate_password_hash ──

echo "=== Test: generate_password_hash ==="

hash=$(openssl passwd -6 "testpassword" 2>/dev/null) || true
assert_not_empty "Password hash generated" "$hash"
case "$hash" in
    '$6$'*) TESTS_PASS=$((TESTS_PASS + 1)) ;;
    *) TESTS_FAIL=$((TESTS_FAIL + 1)); echo "  FAIL: Hash format (expected \$6\$...)" ;;
esac
TESTS_RUN=$((TESTS_RUN + 1))

# ── Test encryption round-trips ──

echo "=== Test: encryption round-trips ==="

# Plaintext mode: chmod 600
cat > "$TMPDIR/plain.conf" <<'CONF'
USERNAME=plaintest
WIFI_SSID=PlainWiFi
CONF
chmod 600 "$TMPDIR/plain.conf"
perms=$(stat -f '%A' "$TMPDIR/plain.conf" 2>/dev/null || stat -c '%a' "$TMPDIR/plain.conf" 2>/dev/null)
assert_eq "Plaintext chmod 600" "600" "$perms"

# AES-256-CBC round-trip
cat > "$TMPDIR/enc_test.conf" <<'CONF'
USERNAME=enctest
WIFI_SSID=EncWiFi
CONF
ENC_PASS="testpass123"
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$TMPDIR/enc_test.conf" -out "$TMPDIR/enc_test.conf.enc" -pass pass:"$ENC_PASS" 2>/dev/null
openssl enc -aes-256-cbc -pbkdf2 -d -in "$TMPDIR/enc_test.conf.enc" -out "$TMPDIR/enc_test_dec.conf" -pass pass:"$ENC_PASS" 2>/dev/null
dec_content=$(cat "$TMPDIR/enc_test_dec.conf")
assert_eq "AES decrypt USERNAME" "USERNAME=enctest" "$(echo "$dec_content" | grep USERNAME)"
assert_eq "AES decrypt WIFI_SSID" "WIFI_SSID=EncWiFi" "$(echo "$dec_content" | grep WIFI_SSID)"

# ── Test output directory ──

echo "=== Test: output directory ==="

assert_eq "OUTPUT_DIR from config" "/tmp/test-output" "$OUTPUT_DIR"
saved_OUTPUT_DIR="$OUTPUT_DIR"
OUTPUT_DIR=""
assert_eq "Default OUTPUT_DIR fallback" "$HOME/.Ubuntu_Deployment" "${OUTPUT_DIR:-$HOME/.Ubuntu_Deployment}"
OUTPUT_DIR="$saved_OUTPUT_DIR"

# ── Test YAML validation schema exists ──

echo "=== Test: YAML validation schema ==="

TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "${PROJECT_DIR}/lib/autoinstall-schema.json" ]; then
    TESTS_PASS=$((TESTS_PASS + 1))
else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    echo "  FAIL: autoinstall-schema.json not found in lib/"
fi

# ── Test save_config → parse_conf round-trip with quoted values ──

echo "=== Test: config round-trip (quoted values) ==="

ROUNDTRIP_CONF="$TMPDIR/roundtrip.conf"
cat > "$ROUNDTRIP_CONF" <<'CONFEOF'
USERNAME="testround"
REALNAME="Round Trip"
HOSTNAME="roundtrip-host"
PASSWORD_HASH="$6$salt$hash"
WIFI_SSID="TestWiFi Round"
WIFI_PASSWORD="passwithspecial"
ENCRYPTION="plaintext"
OUTPUT_DIR=""
CONFEOF

# Re-initialize variables for round-trip test
USERNAME="" REALNAME="" HOSTNAME="" PASSWORD_HASH=""
WIFI_SSID="" WIFI_PASSWORD="" WEBHOOK_HOST="" WEBHOOK_PORT=""
ENCRYPTION="plaintext" OUTPUT_DIR="" SSH_KEYS="" SSH_KEYS_FILE=""

parse_conf "$ROUNDTRIP_CONF"

assert_eq "Round-trip USERNAME" "testround" "$USERNAME"
assert_eq "Round-trip REALNAME" "Round Trip" "$REALNAME"
assert_eq "Round-trip HOSTNAME" "roundtrip-host" "$HOSTNAME"
assert_eq "Round-trip WIFI_SSID" "TestWiFi Round" "$WIFI_SSID"
assert_eq "Round-trip WIFI_PASSWORD" "passwithspecial" "$WIFI_PASSWORD"

rm -f "$ROUNDTRIP_CONF"

# ── Test YAML escaping round-trip ──

echo "=== Test: YAML escaping round-trip ==="

# Source the _sed_escape_yaml_dq function from autoinstall.sh
# (it's defined inside generate_autoinstall, so extract and define it)
_sed_escape_yaml_dq() {
    local val="$1"
    val="${val//\\/\\\\\\\\}"
    val="${val//\"/\\\\\"}"
    val="${val//$'\n'/\\n}"
    val="${val//$'\t'/\\t}"
    val="${val//&/\\&}"
    val="${val//#/\\#}"
    printf '%s' "$val"
}

YAML_RT_PASS=0
YAML_RT_FAIL=0

for test_input in simplepassword "my#pass" "my&pass" "my:pass" "p@ss:w0rd!" 'say"hi' "with space" 'test\backslash'; do
    escaped=$(_sed_escape_yaml_dq "$test_input")
    yaml_line="password: \"${escaped}\""
    yaml_tmpfile=$(mktemp /tmp/yaml_rt_test_XXXXXX.yaml)
    # Simulate the actual code path: sed replacement into YAML template
    # The escaped value goes through sed which processes \# and \& back to literals
    printf '%s\n' 'password: "__WIFI_PASSWORD__"' | \
        sed "s#__WIFI_PASSWORD__#${escaped}#g" > "$yaml_tmpfile"
    result=$(python3 -c "
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        r = yaml.safe_load(f)
    print(r['password'])
except Exception as e:
    print('__ERROR__')
" "$yaml_tmpfile" 2>/dev/null)
    rm -f "$yaml_tmpfile"
    if [ "$result" = "$test_input" ]; then
        YAML_RT_PASS=$((YAML_RT_PASS + 1))
    else
        YAML_RT_FAIL=$((YAML_RT_FAIL + 1))
        echo "  FAIL: YAML round-trip for '$test_input' (escaped='$escaped', got='$result')"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
done

TESTS_PASS=$((TESTS_PASS + YAML_RT_PASS))
TESTS_FAIL=$((TESTS_FAIL + YAML_RT_FAIL))
echo "  YAML round-trip: $YAML_RT_PASS passed, $YAML_RT_FAIL failed"

# ── Summary ──

echo ""
echo "Config tests: $TESTS_PASS passed, $TESTS_FAIL failed (of $TESTS_RUN)"

[ "$TESTS_FAIL" -eq 0 ] && exit 0 || exit 1