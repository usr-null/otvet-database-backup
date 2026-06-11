# mysql-crypto-backup

Automated encrypted MySQL backups using GitHub Actions.

`mysql-crypto-backup` creates off-site MySQL backups by running the dump on the database server, processing it locally, encrypting it with [`age`](https://github.com/FiloSottile/age), and only then transferring the encrypted result to GitHub.

Because encryption happens before any database data leaves the server, backups can be stored as GitHub Release assets, including in public repositories, without exposing database contents.

## Features

* End-to-end encryption using `age`
* Automated backups through GitHub Actions
* Forced-command SSH backup account
* Database-specific MySQL permissions
* Configurable Linux backup user
* Configurable backup command path
* Configurable MySQL user and host pattern
* Configurable MySQL dump command
* Configurable MySQL administration command
* Configurable MySQL character set
* Configurable processing/compression pipeline
* GitHub Release asset storage
* Automatic splitting for GitHub's per-asset release limit
* Explicit failure for oversized backups instead of silent partial uploads
* Public-repository friendly
* No dedicated backup infrastructure required

## Guarantees and limitations

### Security guarantees

* Database contents are encrypted before leaving the backup server.
* GitHub Actions never receives plaintext database data.
* GitHub stores only encrypted backup assets.
* The SSH account is restricted to a single forced command.
* The Linux backup user has password-based login locked.
* The MySQL user is created specifically for backup operations.
* MySQL access is scoped to the selected database and host pattern.
* The MySQL backup password is passed to the backup command through standard input.
* The private `age` key is not required on the server or in GitHub Actions.

> [!IMPORTANT]
> If the private `age` key is lost, backups become unrecoverable.
>
> If the private `age` key is leaked, all backups encrypted with the corresponding public key should be considered compromised. Generate a new key pair and rotate `AGE_PUBLIC_KEY` immediately.

### GitHub Release asset limits

Backups are uploaded as GitHub Release assets.

Each release asset must be smaller than 2 GiB. When the encrypted backup is larger than the per-asset limit, the workflow attempts to split it into multiple smaller assets before upload.

A single GitHub Release can contain up to 1000 assets. This gives a practical single-release capacity of slightly less than 2000 GiB when a backup is split into release assets.

The workflow stores one backup in one GitHub Release. It does not automatically distribute a single backup across multiple releases.

### Failure behavior

The workflow fails explicitly and writes an error to the logs when:

* the encrypted and processed backup is larger than the available disk space on the GitHub Actions runner;
* the backup would require more release assets than GitHub allows in a single release.

The workflow does not silently skip oversized backups and does not report partial backup uploads as successful.

On public GitHub-hosted runners, the single-release asset count limit is unlikely to be reached in practice because runner disk space is much smaller than the practical single-release capacity. The condition is still handled explicitly.

## How it works

1. GitHub Actions connects to the backup server using SSH.
2. A restricted Linux backup user executes a forced command.
3. The server reads the MySQL backup password from standard input.
4. `mysqldump` creates a database dump.
5. The dump stream is processed, for example compressed with `zstd`.
6. The processed stream is encrypted with `age`.
7. GitHub Actions stores the encrypted backup on the runner.
8. If necessary, the encrypted backup is split into multiple release assets.
9. GitHub Actions uploads the encrypted backup assets to a GitHub Release.

At no point does GitHub receive unencrypted database contents.

## Requirements

Install the required packages on the MySQL server:

```sh
apt update
apt install -y mysql-client zstd openssh-server curl
```

Install `age`:

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

## Setup process

Before running `setup.sh`, define the backup server, database, keys, and GitHub Actions secrets.

### 1. Define backup server settings

#### `SSH_HOST`

Hostname or IP address of the server where backups will be executed.

Store this value as a GitHub repository secret.

#### `SSH_PORT`

SSH port of the backup server.

Default:

```text
22
```

Store this value as a GitHub repository secret if the server does not use the default SSH port.

### 2. Define Linux backup account settings

#### `BACKUP_USER`

Linux user used for SSH backup access.

Default:

```text
backup
```

#### `BACKUP_HOME`

Home directory of the Linux backup user.

Default:

```text
/home/<BACKUP_USER>
```

Example with the default user:

```text
/home/backup
```

#### `BACKUP_COMMAND`

Path where the forced backup command will be installed.

Default:

```text
/usr/local/sbin/github-mysql-backup.sh
```

### 3. Define MySQL backup settings

#### `DB_NAME`

Name of the MySQL database to back up.

#### `MYSQL_USER`

MySQL user created or updated for backup operations.

Default:

```text
backup
```

#### `MYSQL_PASSWORD`

Password for the MySQL backup user.

Pass this value to `setup.sh` and store the same value as a GitHub repository secret. The setup script uses it to create or update the MySQL backup user. The GitHub Actions workflow later passes it to the backup command through standard input.

#### `MYSQL_HOST_PATTERN`

MySQL host pattern from which the backup user is allowed to connect.

Default:

```text
localhost
```

For Docker-based deployments, this commonly needs to be set to:

```text
172.18.%
```

#### `MYSQLDUMP_CMD`

Command used to create the database dump.

Default:

```text
mysqldump
```

Example for a TCP connection:

```text
mysqldump --host 127.0.0.1 --port 3306
```

#### `MYSQL_ADMIN_CMD`

Command used by the setup script to configure MySQL users and permissions.

Default:

```text
mysql
```

Examples:

```text
sudo mysql
```

```text
mysql --host 127.0.0.1 --port 3306 --user root -p
```

#### `MYSQL_CHARSET`

Character set used by the MySQL client configuration during backup execution.

Default:

```text
utf8mb4
```

### 4. Define backup processing settings

#### `PROCESS_COMMAND`

Command used to process the dump stream before encryption.

Default:

```text
zstd -19
```

Examples:

```text
cat
```

```text
zstd -10 -T0
```

```text
zstd -22 --ultra
```

```text
zstd -22 --ultra --long=31
```

Aggressive compression settings can require significant memory and may be terminated by the operating system on small VPS instances.

### 5. Generate encryption keys

Generate an `age` key pair on your local machine:

```sh
age-keygen -o backup-key.txt
```

Pass the public key to `setup.sh` as `AGE_PUBLIC_KEY`.

Keep the private key securely, separately from the repository. Prefer keeping an offline copy. If it is lost, existing backups cannot be decrypted.

Do not store the private `age` key in GitHub repository secrets.

### 6. Generate SSH keys

Generate an SSH key pair for GitHub Actions backup access:

```sh
ssh-keygen -t ed25519 -f id_ed25519_backup
```

Pass the public SSH key to `setup.sh` as `SSH_PUBLIC_KEY`.

Store the private SSH key as the `SSH_PRIVATE_KEY` GitHub repository secret. The GitHub Actions workflow uses it to connect to the backup server.

### 7. Create GitHub Actions secrets

The GitHub Actions workflow requires these repository secrets:

| Secret            | Required | Description                                                                 |
| ----------------- | -------: | --------------------------------------------------------------------------- |
| `SSH_HOST`        |      Yes | Hostname or IP address of the backup server.                                |
| `SSH_PORT`        |       No | SSH port of the backup server. Required only when not using port `22`.      |
| `SSH_PRIVATE_KEY` |      Yes | Private SSH key corresponding to the public key passed as `SSH_PUBLIC_KEY`. |
| `MYSQL_PASSWORD`  |      Yes | Password of the MySQL backup user.                                          |

The SSH private key and MySQL password must never be committed to the repository.

## Installation

Run the setup script on the MySQL server as `root`.

### Basic installation

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-password' \
./setup.sh

rm setup.sh
```

### Advanced installation

All configurable setup values can be supplied through environment variables:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

BACKUP_USER='backup' \
BACKUP_HOME='/home/backup' \
BACKUP_COMMAND='/usr/local/sbin/github-mysql-backup.sh' \
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_USER='backup' \
MYSQL_PASSWORD='strong-backup-password' \
MYSQL_HOST_PATTERN='localhost' \
MYSQLDUMP_CMD='mysqldump' \
MYSQL_CHARSET='utf8mb4' \
MYSQL_ADMIN_CMD='mysql' \
PROCESS_COMMAND='zstd -19' \
./setup.sh

rm setup.sh
```

The setup script will:

* create or update the Linux backup user;
* configure the backup user's home directory;
* lock password-based login for the backup user;
* install the forced SSH command;
* install the backup command;
* create or update the MySQL backup user;
* grant backup permissions for the selected database;
* grant the required global `RELOAD` permission;
* print `OK` after successful completion.

## Common configuration examples

### Docker-oriented MySQL host pattern

For deployments where the MySQL connection originates from a Docker network:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-password' \
MYSQL_HOST_PATTERN='172.18.%' \
./setup.sh

rm setup.sh
```

### Custom MySQL administration command

For systems where MySQL administration requires a custom command:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-password' \
MYSQL_ADMIN_CMD='sudo mysql' \
./setup.sh

rm setup.sh
```

### Custom dump command

For `mysqldump` with additional connection options:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-password' \
MYSQLDUMP_CMD='mysqldump --host 127.0.0.1 --port 3306' \
./setup.sh

rm setup.sh
```

### Custom processing command

For custom dump stream processing before encryption:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-password' \
PROCESS_COMMAND='zstd -10 -T0' \
./setup.sh

rm setup.sh
```

## MySQL permissions

The setup script grants the MySQL backup user permissions on the selected database:

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES
ON `<DB_NAME>`.* TO '<MYSQL_USER>'@'<MYSQL_HOST_PATTERN>';
```

It also grants the global `RELOAD` permission:

```sql
GRANT RELOAD ON *.* TO '<MYSQL_USER>'@'<MYSQL_HOST_PATTERN>';
```

## Configuration and secrets reference

| Name                 | Required | Default                                  | Used by                    | Store as GitHub secret | Description                                                      |
| -------------------- | -------: | ---------------------------------------- | -------------------------- | ---------------------: | ---------------------------------------------------------------- |
| `SSH_HOST`           |      Yes | —                                        | GitHub Actions             |                    Yes | Hostname or IP address of the backup server.                     |
| `SSH_PORT`           |       No | `22`                                     | GitHub Actions             |               Optional | SSH port of the backup server.                                   |
| `SSH_PRIVATE_KEY`    |      Yes | —                                        | GitHub Actions             |                    Yes | Private SSH key used by GitHub Actions to connect to the server. |
| `SSH_PUBLIC_KEY`     |      Yes | —                                        | `setup.sh`                 |                     No | Public SSH key installed for the restricted backup user.         |
| `AGE_PUBLIC_KEY`     |      Yes | —                                        | `setup.sh`                 |                     No | Public `age` key used to encrypt backups.                        |
| `DB_NAME`            |      Yes | —                                        | `setup.sh`                 |                     No | MySQL database name to back up.                                  |
| `BACKUP_USER`        |       No | `backup`                                 | `setup.sh`                 |                     No | Linux user used for SSH backup access.                           |
| `BACKUP_HOME`        |       No | `/home/$BACKUP_USER`                     | `setup.sh`                 |                     No | Home directory of the Linux backup user.                         |
| `BACKUP_COMMAND`     |       No | `/usr/local/sbin/github-mysql-backup.sh` | `setup.sh`                 |                     No | Path where the forced backup command is installed.               |
| `MYSQL_USER`         |       No | `backup`                                 | `setup.sh`                 |                     No | MySQL user used for backup operations.                           |
| `MYSQL_PASSWORD`     |      Yes | —                                        | `setup.sh`, GitHub Actions |                    Yes | Password for the MySQL backup user.                              |
| `MYSQL_HOST_PATTERN` |       No | `localhost`                              | `setup.sh`                 |                     No | MySQL host pattern for the backup user.                          |
| `MYSQLDUMP_CMD`      |       No | `mysqldump`                              | `setup.sh`                 |                     No | Command used to create the database dump.                        |
| `MYSQL_CHARSET`      |       No | `utf8mb4`                                | `setup.sh`                 |                     No | MySQL client character set used during backup execution.         |
| `MYSQL_ADMIN_CMD`    |       No | `mysql`                                  | `setup.sh`                 |                     No | Command used to configure MySQL users and grants.                |
| `PROCESS_COMMAND`    |       No | `zstd -19`                               | `setup.sh`                 |                     No | Command used to process the dump stream before encryption.       |
