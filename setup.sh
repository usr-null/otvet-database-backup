#!/bin/sh
set -eu

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

PROGRAM_NAME="mysql-crypto-backup setup"

info() {
  printf '%s\n' "==> $*"
}

ok() {
  printf '%s\n' "OK: $*"
}

warn() {
  printf '%s\n' "WARNING: $*" >&2
}

die() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

: "${BACKUP_USER:=backup}"
: "${BACKUP_HOME:=/home/$BACKUP_USER}"
: "${BACKUP_COMMAND:=/usr/local/sbin/github-mysql-backup.sh}"

: "${SSH_PUBLIC_KEY:=}"
: "${AGE_PUBLIC_KEY:=}"

: "${DB_NAME:=}"
: "${MYSQL_USER:=backup}"
: "${MYSQL_PASSWORD:=}"
: "${MYSQL_HOST_PATTERN:=localhost}"
: "${MYSQLDUMP_CMD:=mysqldump}"
: "${MYSQL_CHARSET:=utf8mb4}"
: "${MYSQL_ADMIN_CMD:=mysql}"

# Empty PROCESS_COMMAND means direct streaming:
#   mysqldump -> age
# Set it to something like "zstd -19" if you want compression before encryption.
: "${PROCESS_COMMAND:=}"

MISSING_REQUIRED=""

require_value() {
  name="$1"
  value="$2"

  if [ -z "$value" ]; then
    MISSING_REQUIRED="${MISSING_REQUIRED}
  - ${name}"
  fi
}

fail_if_missing_required() {
  if [ -n "$MISSING_REQUIRED" ]; then
    printf '%s\n' "ERROR: Missing required environment variables:" >&2
    printf '%s\n' "$MISSING_REQUIRED" >&2
    printf '%s\n' "" >&2
    printf '%s\n' "Example:" >&2
    printf '%s\n' "  SSH_PUBLIC_KEY='ssh-ed25519 ...' \\" >&2
    printf '%s\n' "  AGE_PUBLIC_KEY='age1...' \\" >&2
    printf '%s\n' "  DB_NAME='my_database' \\" >&2
    printf '%s\n' "  MYSQL_PASSWORD='strong-password' \\" >&2
    printf '%s\n' "  ./setup.sh" >&2
    exit 1
  fi
}

reject_newline() {
  name="$1"
  value="$2"
  newline='
'

  case "$value" in
    *"$newline"*)
      die "$name must be a single-line value"
      ;;
  esac
}

require_command() {
  command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    die "Required command not found: $command_name"
  fi
}

first_word() {
  printf '%s\n' "$1" | awk '{ print $1 }'
}

require_command_from_setting() {
  setting_name="$1"
  setting_value="$2"
  command_name="$(first_word "$setting_value")"

  if [ -z "$command_name" ]; then
    die "$setting_name must not be empty"
  fi

  if ! command -v "$command_name" >/dev/null 2>&1; then
    die "$setting_name starts with '$command_name', but that command was not found"
  fi
}

require_absolute_path() {
  name="$1"
  value="$2"

  case "$value" in
    /*)
      ;;
    *)
      die "$name must be an absolute path"
      ;;
  esac

  case "$value" in
    *[[:space:]]*)
      die "$name must not contain whitespace"
      ;;
    *\"*)
      die "$name must not contain double quotes"
      ;;
  esac
}

require_safe_linux_user() {
  name="$1"
  value="$2"

  case "$value" in
    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
      die "$name contains unsupported characters. Use letters, digits, dot, underscore, or hyphen."
      ;;
  esac
}

sql_string() {
  printf "%s" "$1" | sed "s|\\\\|\\\\\\\\|g; s|'|''|g"
}

sql_ident() {
  printf "%s" "$1" | sed 's/`/``/g'
}

shell_string() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

info "Starting $PROGRAM_NAME"

info "Validating required configuration"
require_value SSH_PUBLIC_KEY "$SSH_PUBLIC_KEY"
require_value AGE_PUBLIC_KEY "$AGE_PUBLIC_KEY"
require_value DB_NAME "$DB_NAME"
require_value MYSQL_PASSWORD "$MYSQL_PASSWORD"
fail_if_missing_required

for value_name in \
  BACKUP_USER \
  BACKUP_HOME \
  BACKUP_COMMAND \
  SSH_PUBLIC_KEY \
  AGE_PUBLIC_KEY \
  DB_NAME \
  MYSQL_USER \
  MYSQL_PASSWORD \
  MYSQL_HOST_PATTERN \
  MYSQLDUMP_CMD \
  MYSQL_CHARSET \
  MYSQL_ADMIN_CMD \
  PROCESS_COMMAND
  do
  eval "value=\${$value_name}"
  reject_newline "$value_name" "$value"
done

require_safe_linux_user BACKUP_USER "$BACKUP_USER"
require_absolute_path BACKUP_HOME "$BACKUP_HOME"
require_absolute_path BACKUP_COMMAND "$BACKUP_COMMAND"

case "$AGE_PUBLIC_KEY" in
  age1*)
    ;;
  *)
    die "AGE_PUBLIC_KEY must look like an age public key and start with 'age1'"
    ;;
esac

case "$SSH_PUBLIC_KEY" in
  *" "*)
    ;;
  *)
    die "SSH_PUBLIC_KEY must be a single OpenSSH public key line"
    ;;
esac

case "$SSH_PUBLIC_KEY" in
  ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*)
    ;;
  *)
    die "SSH_PUBLIC_KEY must start with a supported OpenSSH key type"
    ;;
esac

ok "Required configuration is present"

info "Checking local system requirements"
if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root"
fi

require_command awk
require_command bash
require_command chmod
require_command chown
require_command id
require_command install
require_command mktemp
require_command passwd
require_command sed
require_command useradd
require_command usermod
require_command age
require_command_from_setting MYSQL_ADMIN_CMD "$MYSQL_ADMIN_CMD"
require_command_from_setting MYSQLDUMP_CMD "$MYSQLDUMP_CMD"

if [ -n "$PROCESS_COMMAND" ]; then
  require_command_from_setting PROCESS_COMMAND "$PROCESS_COMMAND"
fi

if ! awk '$2 == "/dev/shm" && $3 == "tmpfs" { found = 1 } END { exit !found }' /proc/mounts; then
  die "/dev/shm tmpfs is required for the temporary in-memory MySQL credentials file"
fi

ok "System requirements look good"

info "Configuration summary"
printf '%s\n' "  Linux backup user:        $BACKUP_USER"
printf '%s\n' "  Linux backup home:        $BACKUP_HOME"
printf '%s\n' "  Forced backup command:    $BACKUP_COMMAND"
printf '%s\n' "  MySQL user:               $MYSQL_USER"
printf '%s\n' "  MySQL host pattern:       $MYSQL_HOST_PATTERN"
printf '%s\n' "  Database:                 $DB_NAME"
printf '%s\n' "  MySQL dump command:       $MYSQLDUMP_CMD"
printf '%s\n' "  MySQL character set:      $MYSQL_CHARSET"
if [ -n "$PROCESS_COMMAND" ]; then
  printf '%s\n' "  Processing command:       $PROCESS_COMMAND"
else
  printf '%s\n' "  Processing command:       none; direct mysqldump -> age"
fi
printf '%s\n' "  MySQL password:           configured"
printf '%s\n' "  SSH public key:           configured"
printf '%s\n' "  age public key:           configured"

MYSQL_USER_SQL="$(sql_string "$MYSQL_USER")"
MYSQL_PASSWORD_SQL="$(sql_string "$MYSQL_PASSWORD")"
MYSQL_HOST_PATTERN_SQL="$(sql_string "$MYSQL_HOST_PATTERN")"
DB_NAME_SQL="$(sql_ident "$DB_NAME")"

MYSQLDUMP_CMD_SH="$(shell_string "$MYSQLDUMP_CMD")"
PROCESS_COMMAND_SH="$(shell_string "$PROCESS_COMMAND")"
MYSQL_USER_SH="$(shell_string "$MYSQL_USER")"
MYSQL_CHARSET_SH="$(shell_string "$MYSQL_CHARSET")"
DB_NAME_SH="$(shell_string "$DB_NAME")"
AGE_PUBLIC_KEY_SH="$(shell_string "$AGE_PUBLIC_KEY")"

info "Creating or updating Linux backup user"
if ! id "$BACKUP_USER" >/dev/null 2>&1; then
  useradd -m -d "$BACKUP_HOME" -s /bin/sh "$BACKUP_USER"
  ok "Created Linux user: $BACKUP_USER"
else
  mkdir -p "$BACKUP_HOME"
  usermod -d "$BACKUP_HOME" -s /bin/sh "$BACKUP_USER"
  ok "Updated existing Linux user: $BACKUP_USER"
fi

BACKUP_GROUP="$(id -gn "$BACKUP_USER")"

chown "$BACKUP_USER:$BACKUP_GROUP" "$BACKUP_HOME"
chmod 755 "$BACKUP_HOME"

if passwd -l "$BACKUP_USER" >/dev/null 2>&1; then
  ok "Password-based login locked for: $BACKUP_USER"
else
  warn "Could not lock password for $BACKUP_USER; continuing because key-only SSH may still be enforced by your SSH configuration"
fi

info "Installing forced SSH key"
install -d -m 700 -o "$BACKUP_USER" -g "$BACKUP_GROUP" "$BACKUP_HOME/.ssh"

cat > "$BACKUP_HOME/.ssh/authorized_keys" <<EOF_AUTH
restrict,command="$BACKUP_COMMAND" $SSH_PUBLIC_KEY
EOF_AUTH

chown "$BACKUP_USER:$BACKUP_GROUP" "$BACKUP_HOME/.ssh/authorized_keys"
chmod 600 "$BACKUP_HOME/.ssh/authorized_keys"
ok "Forced SSH command installed in authorized_keys"

info "Installing backup command"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' ''
  printf '%s\n' 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
  printf '%s\n' 'export PATH'
  printf '%s\n' ''
  printf '%s\n' "MYSQLDUMP_CMD_RAW=$MYSQLDUMP_CMD_SH"
  printf '%s\n' "PROCESS_COMMAND_RAW=$PROCESS_COMMAND_SH"
  printf '%s\n' "MYSQL_USER=$MYSQL_USER_SH"
  printf '%s\n' "MYSQL_CHARSET=$MYSQL_CHARSET_SH"
  printf '%s\n' "DB_NAME=$DB_NAME_SH"
  printf '%s\n' "AGE_PUBLIC_KEY=$AGE_PUBLIC_KEY_SH"
  cat <<'EOF_COMMAND_BODY'

if ! awk '$2 == "/dev/shm" && $3 == "tmpfs" { found = 1 } END { exit !found }' /proc/mounts; then
  echo "/dev/shm tmpfs is required for in-memory MySQL credentials file" >&2
  exit 1
fi

MYSQL_RUNTIME_PASSWORD=""
IFS= read -r MYSQL_RUNTIME_PASSWORD || true
MYSQL_RUNTIME_PASSWORD="$(printf '%s' "$MYSQL_RUNTIME_PASSWORD" | tr -d '\r')"

MYSQL_CNF=""

cleanup() {
  if [ -n "$MYSQL_CNF" ]; then
    rm -f "$MYSQL_CNF"
  fi
}

trap cleanup EXIT INT TERM

cnf_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

MYSQL_CNF_USER="$(cnf_escape "$MYSQL_USER")"
MYSQL_CNF_PASSWORD="$(cnf_escape "$MYSQL_RUNTIME_PASSWORD")"
MYSQL_CNF_CHARSET="$(cnf_escape "$MYSQL_CHARSET")"

umask 077
MYSQL_CNF="$(mktemp /dev/shm/mysql-backup.XXXXXX)"
chmod 600 "$MYSQL_CNF"

cat > "$MYSQL_CNF" <<CNF
[client]
user="$MYSQL_CNF_USER"
password="$MYSQL_CNF_PASSWORD"
default-character-set="$MYSQL_CNF_CHARSET"
CNF

read -r -a MYSQLDUMP_CMD_ARR <<< "$MYSQLDUMP_CMD_RAW"

if [ "${#MYSQLDUMP_CMD_ARR[@]}" -eq 0 ]; then
  echo "MYSQLDUMP_CMD is empty" >&2
  exit 1
fi

run_mysqldump() {
  "${MYSQLDUMP_CMD_ARR[0]}" \
    --defaults-extra-file="$MYSQL_CNF" \
    "${MYSQLDUMP_CMD_ARR[@]:1}" \
    --single-transaction \
    --quick \
    --set-gtid-purged=OFF \
    --routines \
    --triggers \
    --events \
    --hex-blob \
    --no-tablespaces \
    --databases "$DB_NAME"
}

if [ -n "$PROCESS_COMMAND_RAW" ]; then
  read -r -a PROCESS_COMMAND_ARR <<< "$PROCESS_COMMAND_RAW"

  if [ "${#PROCESS_COMMAND_ARR[@]}" -eq 0 ]; then
    echo "PROCESS_COMMAND is empty after parsing" >&2
    exit 1
  fi

  run_mysqldump \
    | "${PROCESS_COMMAND_ARR[@]}" \
    | age -r "$AGE_PUBLIC_KEY"
else
  run_mysqldump \
    | age -r "$AGE_PUBLIC_KEY"
fi
EOF_COMMAND_BODY
} > "$BACKUP_COMMAND"

chown root:root "$BACKUP_COMMAND"
chmod 755 "$BACKUP_COMMAND"

if ! bash -n "$BACKUP_COMMAND"; then
  die "Generated backup command has invalid bash syntax: $BACKUP_COMMAND"
fi

ok "Backup command installed: $BACKUP_COMMAND"

info "Creating or updating MySQL backup user and grants"
$MYSQL_ADMIN_CMD <<EOF_SQL
CREATE USER IF NOT EXISTS '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL' IDENTIFIED BY '$MYSQL_PASSWORD_SQL';
ALTER USER '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL' IDENTIFIED BY '$MYSQL_PASSWORD_SQL';

GRANT SELECT, SHOW VIEW, TRIGGER, EVENT
ON \`$DB_NAME_SQL\`.* TO '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL';

GRANT RELOAD ON *.* TO '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL';

FLUSH PRIVILEGES;
EOF_SQL
ok "MySQL backup user and grants configured"

info "Verifying installed files"
if [ ! -s "$BACKUP_HOME/.ssh/authorized_keys" ]; then
  die "authorized_keys was not created correctly"
fi

if [ ! -x "$BACKUP_COMMAND" ]; then
  die "Backup command was not created as an executable file"
fi

if ! bash -n "$BACKUP_COMMAND"; then
  die "Backup command failed final syntax verification"
fi

ok "Installed files verified"

printf '%s\n' ""
printf '%s\n' "Setup completed successfully."
printf '%s\n' ""
printf '%s\n' "Next steps:"
printf '%s\n' "  1. Store the matching private SSH key in GitHub as SSH_PRIVATE_KEY."
printf '%s\n' "  2. Store the same MySQL password in GitHub as MYSQL_PASSWORD."
printf '%s\n' "  3. Set BACKUP_USER in GitHub to: $BACKUP_USER"
printf '%s\n' "  4. Pin your SSH host key in GitHub as SSH_KNOWN_HOSTS."
printf '%s\n' "  5. Run the GitHub Actions workflow."
printf '%s\n' ""
printf '%s\n' "Done."
