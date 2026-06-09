# mysql-crypto-backup

Automated encrypted MySQL backups using GitHub Actions.

This repository provides a simple way to create off-site MySQL database backups using GitHub Actions. Backups are processed on the server, optionally compressed or transformed, encrypted with age, and then stored in GitHub.

Because encryption happens before data leaves the server, backups can safely be stored in a public repository without exposing database contents.

## Features

* End-to-end encryption using age
* Forced-command SSH backup account
* Database-specific MySQL permissions
* Configurable MySQL connection command
* Configurable processing/compression pipeline
* GitHub Actions automation
* Public-repository friendly

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

Keep `backup-key.txt` private. It is required to decrypt your backups.

The public key looks like:

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

The script will:

* create or update a restricted backup user
* install a forced SSH command
* create a dedicated MySQL backup user
* grant access only to the selected database
* install the backup command

## Advanced configuration

### Custom MySQL administration command

Some systems require a custom command for administrative access:

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

For Docker, TCP-only setups, or non-default ports:

```sh
MYSQLDUMP_CMD='mysqldump --host 127.0.0.1 --port 3306'
```

### Custom MySQL host pattern

By default the backup user is created for:

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

Note that aggressive settings such as:

```sh
zstd -22 --ultra --long=31
```

may require several gigabytes of RAM and can be killed by the operating system on small VPS instances.

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
