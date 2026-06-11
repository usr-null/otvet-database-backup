# mysql-crypto-backup

Automated encrypted and processed MySQL backups using GitHub Actions.

`mysql-crypto-backup` creates off-site MySQL backups by running `mysqldump` on the database server, optionally processing the dump stream locally on that server, encrypting the resulting stream with [`age`](https://github.com/FiloSottile/age), and only then transferring the encrypted result to GitHub.

Because encryption happens before any database data leaves the server, backups can be stored as GitHub Release assets, including in public repositories, without exposing database contents.

## Features

* End-to-end encryption using `age`
* Automated backups through GitHub Actions
* Forced-command SSH backup account
* SSH host key pinning through a pinned `known_hosts` entry
* Database-specific MySQL permissions
* No `LOCK TABLES` grant in the default permission model
* No global `PROCESS` grant in the default permission model
* `mysqldump --no-tablespaces` by default
* Configurable Linux backup user
* Configurable backup command path
* Configurable MySQL user and host pattern
* Configurable MySQL dump command
* Configurable MySQL administration command
* Configurable MySQL character set
* Optional configurable processing/compression pipeline
* GitHub Release asset storage
* Automatic splitting for GitHub's per-asset release limit
* Manifest and checksums for every backup release
* Backup retention cleanup workflow
* Explicit failure for oversized backups instead of silent partial uploads
* Public-repository friendly
* No dedicated backup infrastructure required
* Manual, scheduled, and external `repository_dispatch` backup triggers

## Guarantees and limitations

### Security guarantees

* Database contents are encrypted before leaving the backup server.
* GitHub Actions stores only encrypted backup assets.
* The SSH account is restricted to a single forced command.
* SSH host key verification uses a pinned `known_hosts` entry instead of trusting a fresh `ssh-keyscan` result during every run.
* The Linux backup user has password-based login locked.
* The MySQL user is created specifically for backup operations.
* MySQL access is scoped to the selected database and host pattern.
* The MySQL backup password is passed to the backup command through standard input.
* The private `age` key is not required on the server or in GitHub Actions.

> [!IMPORTANT]
> If the private `age` key is lost, backups become unrecoverable.
>
> If the private `age` key is leaked, all backups encrypted with the corresponding public key should be considered compromised. Generate a new key pair and rotate `AGE_PUBLIC_KEY` immediately.

### Plaintext boundary and leak paths

The backup command created by `setup.sh` runs this stream on the backup server:

```text
mysqldump → optional PROCESS_COMMAND → age → GitHub Actions runner
```

By default, `PROCESS_COMMAND` is empty, so the generated backup command streams directly:

```text
mysqldump → age → GitHub Actions runner
```

For compression before encryption, set a trusted processing command, for example:

```text
PROCESS_COMMAND=zstd -19
```

Compression can significantly reduce backup size, but high compression levels can be much slower. For frequent backups or smaller databases, direct streaming without compression, or weak compression such as `zstd -3 -T0`, may be faster end-to-end and may still fit comfortably in GitHub Release assets.

Release asset names, release timestamps, asset sizes, and the encrypted backup size are visible to anyone who can see the repository or releases. This does not reveal database contents, but it can reveal low-risk metadata such as approximate backup size and, if observed over time, the approximate growth rate of the database. Stronger compression can reduce this visible size signal; no compression or weak compression can make the size signal closer to the raw dump size.

The plaintext boundary is everything before `age`.

`MYSQLDUMP_CMD` and any non-empty `PROCESS_COMMAND` run before encryption and must be trusted.

| Path                                                              | Can expose database contents?                | Criticality | Notes                                                                                                                                                                    |
| ----------------------------------------------------------------- | -------------------------------------------- | ----------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `mysqldump stdout → optional PROCESS_COMMAND → age stdout`                 | No, when commands are trusted                 | Low         | This is the intended path. The runner receives the encrypted `age` output.                                                                                               |
| `mysqldump stderr`                                                | Normally no                                  | Medium      | Diagnostic output is not encrypted and may appear in workflow logs. Normal `mysqldump` errors should not contain table data, but stderr is outside the encrypted stream. |
| `PROCESS_COMMAND stderr`                                          | Depends on command                            | High        | Safe commands such as `zstd` should not print backup contents to stderr. A custom command must not write plaintext data to stderr.                                       |
| Unsafe `PROCESS_COMMAND`, for example duplicating input to stderr | Yes                                           | Critical    | Anything before `age` can leak plaintext if configured to print or copy the stream elsewhere.                                                                            |
| Unsafe `MYSQLDUMP_CMD` wrapper                                    | Yes                                           | Critical    | A custom dump command can leak plaintext if it writes database contents to stderr, files, or the network.                                                                |
| Temporary MySQL credentials file in `/dev/shm`                    | No database dump; contains password           | High        | The backup command writes a temporary MySQL client config in memory-backed `/dev/shm` and removes it on exit. It contains the MySQL backup password, not the dump.       |
| GitHub Release assets                                             | No, unless private `age` key is compromised   | Low         | Release assets contain encrypted backup data.                                                                                                                           |
| Lost private `age` key                                            | Backup cannot be decrypted                    | Critical    | Backups become unrecoverable.                                                                                                                                            |
| Leaked private `age` key                                          | Existing encrypted backups may be decrypted   | Critical    | Treat all backups encrypted with that public key as compromised. Rotate `AGE_PUBLIC_KEY`.                                                                                |
| Wrong `BACKUP_USER` in workflow                                   | No dump if forced command is not reached      | Medium      | The workflow must connect to the same Linux user that was configured by `setup.sh`.                                                                                      |
| Missing or bypassed forced SSH command                            | Depends on server configuration               | High        | The workflow is designed for forced-command SSH access. Do not use a normal shell account for backups.                                                                   |

The project guarantees that the intended backup stream is encrypted before it reaches GitHub Actions. It does not make unsafe custom commands safe. Any configured command that runs before `age` is part of the trusted server-side plaintext zone.

### Tablespaces and MySQL privileges

The default backup command uses:

```text
--single-transaction
--quick
--set-gtid-purged=OFF
--no-tablespaces
```

Because `--single-transaction` is used, the default setup does not grant `LOCK TABLES`.

Because `--no-tablespaces` is used, the default setup does not grant global `PROCESS`.

The default MySQL grants are:

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT
ON `<DB_NAME>`.* TO '<MYSQL_USER>'@'<MYSQL_HOST_PATTERN>';

GRANT RELOAD ON *.* TO '<MYSQL_USER>'@'<MYSQL_HOST_PATTERN>';
```

If you previously installed an older version that granted `LOCK TABLES`, re-running the new setup grants the new permission set but may not automatically revoke an old existing grant. You can revoke it manually if desired:

```sql
REVOKE LOCK TABLES
ON `<DB_NAME>`.* FROM '<MYSQL_USER>'@'<MYSQL_HOST_PATTERN>';
```

### GitHub Release asset limits

Backups are uploaded as GitHub Release assets.

Each release asset must be smaller than 2 GiB. When the encrypted backup is larger than the per-asset limit, the workflow splits it into multiple smaller assets before upload.

A single GitHub Release can contain up to 1000 assets. This gives a practical single-release capacity of slightly less than 2000 GiB when a backup is split into release assets.

The workflow stores one backup in one GitHub Release. It does not currently distribute a single backup across multiple releases.

Splitting one backup across multiple GitHub Releases is possible, but it is not implemented yet. In practice, this is unlikely to matter for public GitHub-hosted runners, because such large backups would normally exceed the available runner disk space before reaching the practical single-release asset capacity.

### Failure behavior

The workflow fails explicitly and writes an error to the logs when:

* required configuration is missing;
* the pinned SSH host key is missing or invalid;
* `GITHUB_TOKEN` cannot create releases;
* the encrypted and processed backup is larger than the available disk space on the GitHub Actions runner;
* the backup would require more release assets than GitHub allows in a single release;
* SSH connection, forced command execution, or release upload fails.

The workflow does not silently skip oversized backups and does not report partial backup uploads as successful.

Before running the expensive backup stream, the workflow creates and deletes a temporary draft release to verify that `GITHUB_TOKEN` can create releases. If this check fails with `HTTP 403: Resource not accessible by integration`, enable write permissions for GitHub Actions in the repository settings.

Backup releases are created as drafts first. If asset upload fails after draft release creation, the workflow attempts to delete the incomplete draft release and its tag.

## How it works

1. GitHub Actions loads a pinned SSH `known_hosts` entry.
2. GitHub Actions connects to the backup server using SSH.
3. A restricted Linux backup user executes a forced command.
4. The server reads the MySQL backup password from standard input.
5. `mysqldump` creates a database dump.
6. If `PROCESS_COMMAND` is configured, the dump stream is processed, for example compressed with `zstd`.
7. The resulting stream is encrypted with `age`.
8. GitHub Actions stores the encrypted backup on the runner.
9. If necessary, the encrypted backup is split into multiple release assets.
10. GitHub Actions creates a GitHub Release and uploads the encrypted backup assets, manifest, and checksums.
11. The cleanup workflow deletes old backup releases according to `RETENTION_KEEP_LAST`.

At no point should GitHub receive unencrypted database contents when trusted dump and optional processing commands are used.

## Requirements

Install the required packages on the MySQL server:

```sh
apt update
apt install -y mysql-client openssh-server curl
```

Install `zstd` only if you plan to use a `zstd`-based `PROCESS_COMMAND`:

```sh
apt install -y zstd
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

Before running `setup.sh`, define the backup server, database, keys, and GitHub Actions configuration.

### 1. Define server-side setup variables

These variables are used by `setup.sh`.

| Variable             | Required | Default                                  | Secret? | Description                                                                                           |
| -------------------- | -------: | ---------------------------------------- | ------: | ----------------------------------------------------------------------------------------------------- |
| `SSH_PUBLIC_KEY`     | Yes      | —                                        | No      | Public SSH key installed for the restricted backup user.                                              |
| `AGE_PUBLIC_KEY`     | Yes      | —                                        | No      | Public `age` key used to encrypt backups.                                                             |
| `DB_NAME`            | Yes      | —                                        | No      | MySQL database name to back up.                                                                       |
| `MYSQL_PASSWORD`     | Yes      | —                                        | Yes     | Password for the MySQL backup user. Also required by GitHub Actions.                                  |
| `BACKUP_USER`        | No       | `backup`                                 | No      | Linux user used for SSH backup access.                                                                |
| `BACKUP_HOME`        | No       | `/home/$BACKUP_USER`                     | No      | Home directory of the Linux backup user.                                                              |
| `BACKUP_COMMAND`     | No       | `/usr/local/sbin/github-mysql-backup.sh` | No      | Path where the forced backup command is installed.                                                    |
| `MYSQL_USER`         | No       | `backup`                                 | No      | MySQL user used for backup operations.                                                                |
| `MYSQL_HOST_PATTERN` | No       | `localhost`                              | No      | MySQL host pattern for the backup user.                                                               |
| `MYSQLDUMP_CMD`      | No       | `mysqldump`                              | No      | Command used to create the database dump. Runs before encryption and must be trusted.                  |
| `MYSQL_CHARSET`      | No       | `utf8mb4`                                | No      | MySQL client character set used during backup execution.                                              |
| `MYSQL_ADMIN_CMD`    | No       | `mysql`                                  | No      | Command used by `setup.sh` to configure MySQL users and grants.                                       |
| `PROCESS_COMMAND`    | No       | empty                                    | No      | Optional command used to process the dump stream before encryption. Empty means direct `mysqldump → age`. Any non-empty command runs before encryption and must be trusted. |

Common examples:

```text
MYSQL_HOST_PATTERN=172.18.%
MYSQLDUMP_CMD=mysqldump --host 127.0.0.1 --port 3306
MYSQL_ADMIN_CMD=mysql --host 127.0.0.1 --port 3306 --user root -p
PROCESS_COMMAND=zstd -19
```

Leave `PROCESS_COMMAND` unset or set it to an empty value for direct streaming without compression. Set it to `zstd -19` when you prefer smaller backups and can accept slower server-side compression.

### 2. Generate encryption keys

Generate an `age` key pair on your local machine:

```sh
age-keygen -o backup-key.txt
```

Pass the public key to `setup.sh` as `AGE_PUBLIC_KEY`.

Keep the private key securely, separately from the repository. Prefer keeping offline copies. If it is lost, existing backups cannot be decrypted.

Do not store the private `age` key in GitHub repository secrets.

### 3. Generate SSH keys

Generate an SSH key pair for GitHub Actions backup access:

```sh
ssh-keygen -t ed25519 -f id_ed25519_backup
```

Pass the public SSH key to `setup.sh` as `SSH_PUBLIC_KEY`.

Store the private SSH key as the `SSH_PRIVATE_KEY` GitHub repository secret.

### 4. Pin the SSH host key

Create a pinned `known_hosts` entry for the backup server from a trusted machine or trusted network path:

```sh
SSH_HOST='example.com'
SSH_PORT='22'

ssh-keyscan -p "$SSH_PORT" -H "$SSH_HOST" > ssh_known_hosts
ssh-keygen -l -f ssh_known_hosts
```

Review the fingerprint out of band if possible.

Store the full contents of `ssh_known_hosts` as `SSH_KNOWN_HOSTS` in GitHub repository secrets or variables.

Use a secret if you also want to hide host metadata. Use a variable if you consider the host key public operational metadata.

For a non-default SSH port, keep the exact `ssh-keyscan -p` output. OpenSSH uses a `[host]:port` form in `known_hosts` for non-default ports.

### 5. Generate the MySQL backup password

Generate a password for the MySQL backup user.

Pass this password to `setup.sh` as `MYSQL_PASSWORD`.

Store the same password as the `MYSQL_PASSWORD` GitHub repository secret. GitHub Actions sends it to the backup command through standard input.

### 6. Define GitHub Actions secrets

Secrets are used for sensitive values and for operational metadata that you prefer not to expose.

| Secret            | Required | Description                                                                                                         |
| ----------------- | -------: | ------------------------------------------------------------------------------------------------------------------- |
| `SSH_HOST`        | Yes      | Hostname or IP address of the backup server.                                                                        |
| `SSH_PRIVATE_KEY` | Yes      | Private SSH key corresponding to the public key passed as `SSH_PUBLIC_KEY`.                                         |
| `MYSQL_PASSWORD`  | Yes      | Password of the MySQL backup user.                                                                                  |
| `SSH_KNOWN_HOSTS` | Yes      | Pinned SSH `known_hosts` entry for the backup server. Can also be stored as a repository variable.                  |
| `SSH_PORT`        | No       | SSH port of the backup server. Required only when not using port `22`. Can also be stored as a repository variable. |
| `BACKUP_USER`     | No       | Linux user used for SSH backup access. Can also be stored as a repository variable.                                 |

`SSH_KNOWN_HOSTS`, `SSH_PORT`, and `BACKUP_USER` are not credentials, but they can be stored as secrets if you prefer to hide operational metadata. When both a secret and a variable are set for the same name, the workflow uses the secret first.

The SSH private key and MySQL password must never be committed to the repository.

> [!NOTE]
> GitHub Actions masks every exact secret value in workflow logs. Very short secrets, such as `22`, `3306`, `backup`, or other common short strings, may accidentally match parts of normal log output and produce confusing `***` fragments in progress counters, byte counts, URLs, or diagnostic messages.
>
> This does not mean that backup data was leaked or corrupted. It is only log masking.
>
> For non-sensitive short values such as `SSH_PORT` or `BACKUP_USER`, prefer repository variables instead of secrets unless you specifically want to hide that operational metadata.


### 7. Define GitHub Actions variables

Repository variables are used for non-sensitive workflow configuration.

| Variable              | Required | Default        | Description                                                                                              |
| --------------------- | -------: | -------------- | -------------------------------------------------------------------------------------------------------- |
| `SSH_KNOWN_HOSTS`     | Yes      | —              | Pinned SSH `known_hosts` entry. Can be stored as a secret instead if preferred. Secret wins.             |
| `BACKUP_USER`         | No       | `backup`       | Linux user used for SSH backup access. Must match the `BACKUP_USER` used during `setup.sh`. Secret wins. |
| `BACKUP_NAME`         | No       | `mysql`        | Human-readable backup name used in release titles and metadata.                                          |
| `RELEASE_PREFIX`      | No       | `mysql-backup` | Prefix used for GitHub Release tags. Also used by the retention cleanup workflow.                        |
| `ASSET_PREFIX`        | No       | `mysql-backup` | Prefix used for uploaded release asset names.                                                            |
| `SPLIT_SIZE_BYTES`    | No       | `2000000000`   | Split size for release assets. Must be lower than 2 GiB.                                                 |
| `SSH_PORT`            | No       | `22`           | SSH port. Can be stored as a secret instead if preferred. Secret wins.                                   |
| `RETENTION_KEEP_LAST` | No       | `30`           | Number of newest backup releases to keep. Used by `cl-backup.yml`.                                       |

The backup workflow and cleanup workflow both use `RELEASE_PREFIX`. Keep it the same for both workflows by using the same repository variable or the shared default.

The workflow also uses GitHub's automatically generated `GITHUB_TOKEN` through `github.token`. You do not need to create a personal access token. The workflows grant it `contents: write` permission to create and delete releases.

If release creation fails with `HTTP 403: Resource not accessible by integration`, check:

```text
Repository → Settings → Actions → General → Workflow permissions → Read and write permissions
```

## Installation

Run the setup script on the MySQL server as `root`.

### Basic installation

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/main/setup.sh -o setup.sh
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
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/main/setup.sh -o setup.sh
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
* use `mysqldump --no-tablespaces` in the generated backup command;
* stream directly to `age` when `PROCESS_COMMAND` is empty;
* print `OK` after successful completion.

## GitHub Actions workflows

Create these workflow files:

```text
.github/workflows/mk-backup.yml
.github/workflows/cl-backup.yml
```

`mk-backup.yml` creates encrypted backup releases. It can be started manually, by GitHub schedule, or externally through `repository_dispatch`.

`cl-backup.yml` deletes old backup releases according to `RETENTION_KEEP_LAST`.

The cleanup workflow is triggered:

* manually through `workflow_dispatch`;
* daily at 17:00 UTC;
* after a successful `Encrypted MySQL backup` workflow run.

No extra synchronization is required as long as both workflows use the same `RELEASE_PREFIX`.

### External backup triggering with repository_dispatch

The backup workflow also supports GitHub's `repository_dispatch` event. This allows a trusted external system, such as a database server, monitoring service, cron job, or `systemd` timer, to trigger a backup through the GitHub API.

This can be useful when GitHub `schedule` is not precise enough for your backup policy. Scheduled workflow runs may be delayed during periods of high GitHub Actions load, and queued scheduled jobs may be dropped if the load is high enough. A server-side timer that sends `repository_dispatch` gives you control over when dispatch requests are sent.

The workflow listens for this dispatch event type:

```yaml
repository_dispatch:
  types: [run-backup]
```

Example request:

```sh
curl -fsS -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/OWNER/REPOSITORY/dispatches \
  -d '{"event_type":"run-backup","client_payload":{"source":"external"}}'
```

The token used for dispatch must be allowed to create repository dispatch events for the repository. Store this token only on the trusted machine that triggers backups. Do not commit it to the repository.

`repository_dispatch` is an additional trigger. It does not replace `workflow_dispatch` or `schedule`; you can keep all three enabled.

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

### Direct streaming without compression

By default, `PROCESS_COMMAND` is empty. The server streams directly:

```text
mysqldump → age
```

This avoids compression CPU cost and can be faster for smaller databases that still fit comfortably in GitHub Release assets. The trade-off is that encrypted asset sizes may be larger, which can make database size and growth-rate metadata easier to estimate from public release assets. This is usually a low risk compared with content exposure, but it is worth considering for public repositories.

### Custom processing command

For optional dump stream processing before encryption, for example high-compression `zstd`:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-password' \
PROCESS_COMMAND='zstd -19' \
./setup.sh

rm setup.sh
```

## Restore

Each backup release contains:

* encrypted backup asset, or encrypted backup parts;
* a manifest JSON file;
* a SHA256 checksums file;
* release notes with restore commands generated for that specific backup mode.

For a single-file backup, the encrypted backup asset is named like:

```text
mysql-backup-YYYYMMDDTHHMMSSZ.age
```

For a split backup, the encrypted backup assets are named like:

```text
mysql-backup-YYYYMMDDTHHMMSSZ.age.part-0000
mysql-backup-YYYYMMDDTHHMMSSZ.age.part-0001
mysql-backup-YYYYMMDDTHHMMSSZ.age.part-0002
```

### Generic restore flow

Download all assets from the release into one directory.

Verify the downloaded release assets:

```sh
sha256sum -c mysql-backup-YYYYMMDDTHHMMSSZ.sha256
```

If the backup is split, assemble it first:

```sh
cat mysql-backup-YYYYMMDDTHHMMSSZ.age.part-* > mysql-backup-YYYYMMDDTHHMMSSZ.age
```

Verify the assembled encrypted backup using the SHA256 value from the manifest or release notes:

```sh
printf '%s  %s\n' '<sha256-from-manifest>' 'mysql-backup-YYYYMMDDTHHMMSSZ.age' | sha256sum -c -
```

Decrypt with your private `age` key:

```sh
age -d -i backup-key.txt < mysql-backup-YYYYMMDDTHHMMSSZ.age > backup.processed
```

`backup.processed` is the exact output that was encrypted on the server.

If `PROCESS_COMMAND` was empty, `backup.processed` is already a SQL dump. You can rename it or restore from it directly after inspection:

```sh
mv backup.processed backup.sql
mysql < backup.sql
```

If you used compression, reverse that processing step first. For example, if you configured:

```text
PROCESS_COMMAND=zstd -19
```

then decompress it:

```sh
zstd -d -c backup.processed > backup.sql
```

Then inspect and restore the SQL dump according to your MySQL restore procedure:

```sh
mysql < backup.sql
```

If you configured a different custom `PROCESS_COMMAND`, reverse that processing command instead of using `zstd -d`.

## Configuration reference

| Name                  | Required | Default                                  | Used by                    | Store as GitHub secret | Description                                                                                            |
| --------------------- | -------: | ---------------------------------------- | -------------------------- | ---------------------: | ------------------------------------------------------------------------------------------------------ |
| `SSH_HOST`            | Yes      | —                                        | GitHub Actions             | Yes                    | Hostname or IP address of the backup server.                                                           |
| `SSH_PORT`            | No       | `22`                                     | GitHub Actions             | Optional               | SSH port of the backup server. Secret takes priority over repository variable.                         |
| `SSH_KNOWN_HOSTS`     | Yes      | —                                        | GitHub Actions             | Optional               | Pinned SSH `known_hosts` entry for the backup server. Secret takes priority over repository variable.  |
| `SSH_PRIVATE_KEY`     | Yes      | —                                        | GitHub Actions             | Yes                    | Private SSH key used by GitHub Actions to connect to the backup server.                                |
| `SSH_PUBLIC_KEY`      | Yes      | —                                        | `setup.sh`                 | No                     | Public SSH key installed for the restricted backup user.                                               |
| `AGE_PUBLIC_KEY`      | Yes      | —                                        | `setup.sh`                 | No                     | Public `age` key used to encrypt backups.                                                              |
| `DB_NAME`             | Yes      | —                                        | `setup.sh`                 | No                     | MySQL database name to back up.                                                                        |
| `BACKUP_USER`         | No       | `backup`                                 | `setup.sh`, GitHub Actions | Optional               | Linux user used for SSH backup access. Must match in setup and workflow. Secret takes priority.        |
| `BACKUP_HOME`         | No       | `/home/$BACKUP_USER`                     | `setup.sh`                 | No                     | Home directory of the Linux backup user.                                                               |
| `BACKUP_COMMAND`      | No       | `/usr/local/sbin/github-mysql-backup.sh` | `setup.sh`                 | No                     | Path where the forced backup command is installed.                                                     |
| `MYSQL_USER`          | No       | `backup`                                 | `setup.sh`                 | No                     | MySQL user used for backup operations.                                                                 |
| `MYSQL_PASSWORD`      | Yes      | —                                        | `setup.sh`, GitHub Actions | Yes                    | Password for the MySQL backup user.                                                                    |
| `MYSQL_HOST_PATTERN`  | No       | `localhost`                              | `setup.sh`                 | No                     | MySQL host pattern for the backup user.                                                                |
| `MYSQLDUMP_CMD`       | No       | `mysqldump`                              | `setup.sh`                 | No                     | Command used to create the database dump. Runs before encryption and must be trusted.                  |
| `MYSQL_CHARSET`       | No       | `utf8mb4`                                | `setup.sh`                 | No                     | MySQL client character set used during backup execution.                                               |
| `MYSQL_ADMIN_CMD`     | No       | `mysql`                                  | `setup.sh`                 | No                     | Command used to configure MySQL users and grants.                                                      |
| `PROCESS_COMMAND`     | No       | empty                                    | `setup.sh`                 | No                     | Optional command used to process the dump stream before encryption. Empty means direct `mysqldump → age`. Any non-empty command runs before encryption and must be trusted. |
| `BACKUP_NAME`         | No       | `mysql`                                  | GitHub Actions             | No                     | Human-readable backup name used in release titles and metadata.                                        |
| `RELEASE_PREFIX`      | No       | `mysql-backup`                           | GitHub Actions             | No                     | Prefix used for backup release tags and retention cleanup matching.                                    |
| `ASSET_PREFIX`        | No       | `mysql-backup`                           | GitHub Actions             | No                     | Prefix used for uploaded release asset names.                                                          |
| `SPLIT_SIZE_BYTES`    | No       | `2000000000`                             | GitHub Actions             | No                     | Split size for release assets. Must be lower than 2 GiB.                                               |
| `RETENTION_KEEP_LAST` | No       | `30`                                     | GitHub Actions             | No                     | Number of newest backup releases to keep. Used by `cl-backup.yml`.                                     |
