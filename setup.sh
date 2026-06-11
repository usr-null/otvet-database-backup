#!/bin/sh
set -eu

: "${BACKUP_USER:=backup}"
: "${BACKUP_HOME:=/home/$BACKUP_USER}"
: "${BACKUP_COMMAND:=/usr/local/sbin/github-mysql-backup.sh}"

: "${SSH_PUBLIC_KEY:?set SSH_PUBLIC_KEY}"
: "${AGE_PUBLIC_KEY:?set AGE_PUBLIC_KEY}"

: "${DB_NAME:?set DB_NAME}"
: "${MYSQL_USER:=backup}"
: "${MYSQL_PASSWORD:?set MYSQL_PASSWORD}"
: "${MYSQL_HOST_PATTERN:=localhost}"
: "${MYSQLDUMP_CMD:=mysqldump}"
: "${MYSQL_CHARSET:=utf8mb4}"
: "${MYSQL_ADMIN_CMD:=mysql}"

: "${PROCESS_COMMAND:=zstd -19}"

sql_string() {
  printf "%s" "$1" | sed "s|\\\\|\\\\\\\\|g; s|'|''|g"
}

sql_ident() {
  printf "%s" "$1" | sed 's/`/``/g'
}

shell_string() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

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

if ! id "$BACKUP_USER" >/dev/null 2>&1; then
  useradd -m -d "$BACKUP_HOME" -s /bin/sh "$BACKUP_USER"
else
  mkdir -p "$BACKUP_HOME"
  usermod -d "$BACKUP_HOME" -s /bin/sh "$BACKUP_USER"
fi

chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME"
chmod 755 "$BACKUP_HOME"

passwd -l "$BACKUP_USER" >/dev/null 2>&1 || true

install -d -m 700 -o "$BACKUP_USER" -g "$BACKUP_USER" "$BACKUP_HOME/.ssh"

cat > "$BACKUP_HOME/.ssh/authorized_keys" <<EOF_AUTH
restrict,command="$BACKUP_COMMAND" $SSH_PUBLIC_KEY
EOF_AUTH

chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME/.ssh/authorized_keys"
chmod 600 "$BACKUP_HOME/.ssh/authorized_keys"

cat > "$BACKUP_COMMAND" <<EOF_COMMAND
#!/bin/bash
set -euo pipefail

MYSQLDUMP_CMD_RAW=$MYSQLDUMP_CMD_SH
PROCESS_COMMAND_RAW=$PROCESS_COMMAND_SH
MYSQL_USER=$MYSQL_USER_SH
MYSQL_CHARSET=$MYSQL_CHARSET_SH
DB_NAME=$DB_NAME_SH
AGE_PUBLIC_KEY=$AGE_PUBLIC_KEY_SH

if ! awk '\$2 == "/dev/shm" && \$3 == "tmpfs" { found = 1 } END { exit !found }' /proc/mounts; then
  echo "/dev/shm tmpfs is required for in-memory MySQL credentials file" >&2
  exit 1
fi

MYSQL_RUNTIME_PASSWORD=""
IFS= read -r MYSQL_RUNTIME_PASSWORD || true
MYSQL_RUNTIME_PASSWORD="\$(printf '%s' "\$MYSQL_RUNTIME_PASSWORD" | tr -d '\r')"

MYSQL_CNF=""
cleanup() {
  if [ -n "\$MYSQL_CNF" ]; then
    rm -f "\$MYSQL_CNF"
  fi
}
trap cleanup EXIT INT TERM

cnf_escape() {
  local s="\$1"
  s="\${s//\\\\/\\\\\\\\}"
  s="\${s//\"/\\\\\"}"
  printf '%s' "\$s"
}

MYSQL_CNF_USER="\$(cnf_escape "\$MYSQL_USER")"
MYSQL_CNF_PASSWORD="\$(cnf_escape "\$MYSQL_RUNTIME_PASSWORD")"
MYSQL_CNF_CHARSET="\$(cnf_escape "\$MYSQL_CHARSET")"

umask 077
MYSQL_CNF="\$(mktemp /dev/shm/mysql-backup.XXXXXX)"
chmod 600 "\$MYSQL_CNF"

cat > "\$MYSQL_CNF" <<CNF
[client]
user="\$MYSQL_CNF_USER"
password="\$MYSQL_CNF_PASSWORD"
default-character-set="\$MYSQL_CNF_CHARSET"
CNF

read -r -a MYSQLDUMP_CMD_ARR <<< "\$MYSQLDUMP_CMD_RAW"
read -r -a PROCESS_COMMAND_ARR <<< "\$PROCESS_COMMAND_RAW"

"\${MYSQLDUMP_CMD_ARR[0]}" \\
  --defaults-extra-file="\$MYSQL_CNF" \\
  "\${MYSQLDUMP_CMD_ARR[@]:1}" \\
  --single-transaction \\
  --set-gtid-purged=OFF \\
  --routines \\
  --triggers \\
  --events \\
  --hex-blob \\
  --no-tablespaces \\
  --databases "\$DB_NAME" \\
  | "\${PROCESS_COMMAND_ARR[@]}" \\
  | age -r "\$AGE_PUBLIC_KEY"
EOF_COMMAND

chown root:root "$BACKUP_COMMAND"
chmod 755 "$BACKUP_COMMAND"

$MYSQL_ADMIN_CMD <<EOF_SQL
CREATE USER IF NOT EXISTS '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL' IDENTIFIED BY '$MYSQL_PASSWORD_SQL';
ALTER USER '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL' IDENTIFIED BY '$MYSQL_PASSWORD_SQL';

GRANT SELECT, SHOW VIEW, TRIGGER, EVENT
ON \`$DB_NAME_SQL\`.* TO '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL';

GRANT RELOAD ON *.* TO '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL';

FLUSH PRIVILEGES;
EOF_SQL

echo "OK"
