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

sql_string() {
  printf "%s" "$1" | sed "s/'/''/g"
}

sql_ident() {
  printf "%s" "$1" | sed 's/`/``/g'
}

MYSQL_USER_SQL="$(sql_string "$MYSQL_USER")"
MYSQL_PASSWORD_SQL="$(sql_string "$MYSQL_PASSWORD")"
MYSQL_HOST_PATTERN_SQL="$(sql_string "$MYSQL_HOST_PATTERN")"
DB_NAME_SQL="$(sql_ident "$DB_NAME")"

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

cat > "$BACKUP_HOME/.ssh/authorized_keys" <<EOF
restrict,command="$BACKUP_COMMAND" $SSH_PUBLIC_KEY
EOF

chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME/.ssh/authorized_keys"
chmod 600 "$BACKUP_HOME/.ssh/authorized_keys"

cat > "$BACKUP_COMMAND" <<EOF
#!/bin/sh
set -eu

IFS= read -r MYSQL_RUNTIME_PASSWORD
MYSQL_RUNTIME_PASSWORD="${MYSQL_RUNTIME_PASSWORD%"$(printf '\r')"}"

$MYSQLDUMP_CMD \\
  -u "$MYSQL_USER" \\
  -p"\$MYSQL_RUNTIME_PASSWORD" \\
  --single-transaction \\
  --routines \\
  --triggers \\
  --events \\
  --hex-blob \\
  --no-tablespaces \\
  --default-character-set="$MYSQL_CHARSET" \\
  --databases "$DB_NAME" \\
| zstd -19 \\
| age -r "$AGE_PUBLIC_KEY"
EOF

chown root:root "$BACKUP_COMMAND"
chmod 755 "$BACKUP_COMMAND"

$MYSQL_ADMIN_CMD <<EOF
CREATE USER IF NOT EXISTS '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL' IDENTIFIED BY '$MYSQL_PASSWORD_SQL';
ALTER USER '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL' IDENTIFIED BY '$MYSQL_PASSWORD_SQL';

GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES
ON \`$DB_NAME_SQL\`.* TO '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL';

GRANT RELOAD ON *.* TO '$MYSQL_USER_SQL'@'$MYSQL_HOST_PATTERN_SQL';

FLUSH PRIVILEGES;
EOF

echo "OK"
