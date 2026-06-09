# mysql-crypto-backup

Automated encrypted MySQL backups using GitHub Actions.

This repository provides a simple way to create off-site MySQL database backups using GitHub Actions. Backups are processed on the server, optionally compressed or transformed, encrypted with age, and only then transferred to GitHub.

Because encryption happens before any data leaves the server, backups can safely be stored in a public repository without exposing database contents.

By combining strong end-to-end encryption with GitHub's generous free infrastructure for public repositories, this project provides a low-cost, automated, and privacy-preserving backup solution without requiring dedicated backup servers or paid cloud storage.

Backups are stored as GitHub Release assets and automatically split across multiple files when necessary. This avoids repository file size limitations while allowing large backup histories to be retained using GitHub's release storage infrastructure.

## Features

* End-to-end encryption using age
* Automated GitHub Actions backups
* Forced-command SSH backup account
* Database-specific MySQL permissions
* Configurable MySQL connection command
* Configurable processing/compression pipeline
* GitHub Release asset storage
* Automatic backup file splitting
* Public-repository friendly
* No dedicated backup infrastructure required

## How it works

1. GitHub Actions connects to the server using SSH.
2. A restricted backup user executes a forced command.
3. The server reads the MySQL backup password from standard input.
4. mysqldump generates a database dump.
5. The dump is optionally compressed or processed.
6. The resulting stream is encrypted with age.
7. GitHub Actions uploads the encrypted backup to a GitHub Release.
8. Large backups are automatically split into multiple assets to avoid file size limits.

At no point does GitHub receive unencrypted database contents.

## Installing

Install the required packages on the MySQL server:

```sh
apt update
apt install -y mysql-client zstd openssh-server curl
```

Install age:

```sh
AGE_VERSION="1.2.1"

curl -fsSL \
  "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
  -o age.tar.gz

tar -xzf age.tar.gz

install age/age /usr/local/bin/age
install age/age-keygen /usr/local/bin/age-keygen

rm -rf age age.tar.gz
```

Generate an age key pair on your local machine:

```sh
age-keygen -o backup-key.txt
```

Keep `backup-key.txt` private. It is required to decrypt backups.

The public key will look similar to:

```text
age1...
```

Generate an SSH key for backup access:

```sh
ssh-keygen -t ed25519 -f id_ed25519_backup
```

## Basic setup

Run the setup script on the MySQL server as root:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh | \
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-password' \
sh
```

The setup script will:

* create or update a restricted backup user
* install a forced SSH command
* create a dedicated MySQL backup user
* grant access only to the selected database
* install the backup command

## Advanced configuration

### Custom MySQL administration command

Some systems require a custom administration command:

```sh
MYSQL_ADMIN_CMD='sudo mysql'
```

Example:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh | \
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-password' \
MYSQL_ADMIN_CMD='sudo mysql' \
sh
```

### Custom mysqldump command

Useful for Docker, TCP-only deployments, or non-default ports:

```sh
MYSQLDUMP_CMD='mysqldump --host 127.0.0.1 --port 3306'
```

### Custom MySQL host pattern

By default the MySQL backup user is created for:

```text
localhost
```

You can allow a different source address pattern:

```sh
MYSQL_HOST_PATTERN='172.18.%'
```

### Custom processing pipeline

Before encryption the dump is passed through a processing command.

Default:

```sh
PROCESS_COMMAND='zstd -19'
```

Examples:

```sh
PROCESS_COMMAND='cat'
```

```sh
PROCESS_COMMAND='zstd -10 -T0'
```

```sh
PROCESS_COMMAND='zstd -22 --ultra'
```

For maximum compression:

```sh
PROCESS_COMMAND='zstd -22 --ultra --long=31'
```

Be aware that aggressive compression settings can consume large amounts of memory and may be terminated by the operating system on small VPS instances.

## Restoring

Decrypt:

```sh
age -d -i backup-key.txt backup.sql.zst.age > backup.sql.zst
```

Decompress:

```sh
zstd -d backup.sql.zst -o backup.sql
```

Restore:

```sh
mysql my_database < backup.sql
```

## Security model

* Database contents are encrypted before leaving the server.
* GitHub never receives plaintext database data.
* The SSH account is restricted to a single forced command.
* The MySQL user only receives the permissions required for backups.
* The backup password is supplied through standard input and is not stored in GitHub.
* Public repositories can be used safely because all backup data is encrypted before upload.

This approach combines the cost advantages and generous free storage available to public GitHub repositories with strong cryptographic privacy guarantees.
