# mysql-crypto-backup

Automated encrypted MySQL backups using GitHub Actions.

`mysql-crypto-backup` creates off-site MySQL backups by running the dump on the database server, processing it locally, encrypting it with [`age`](https://github.com/FiloSottile/age), and only then transferring the encrypted result to GitHub.

Because encryption happens before any database data leaves the server, backups can be stored as GitHub Release assets, including in public repositories, without exposing database contents.

## Files

```text
setup.sh
.github/workflows/mk-backup.yml
.github/workflows/cl-backup.yml
```

`mk-backup.yml` creates encrypted backup releases.

`cl-backup.yml` deletes old backup releases according to the configured retention policy.

Both workflows use the same concurrency group, so cleanup will not run at the same time as a backup.

## Features

* End-to-end encryption using `age`
* Automated backups through GitHub Actions
* Forced-command SSH backup account
* Pinned SSH host key verification through `SSH\_KNOWN\_HOSTS`
* Database-specific MySQL permissions
* Minimal MySQL grants for the default dump mode
* Configurable Linux backup user
* Configurable backup command path
* Configurable MySQL user and host pattern
* Configurable MySQL dump command
* Configurable MySQL administration command
* Configurable MySQL character set
* Configurable processing/compression pipeline
* GitHub Release asset storage
* Automatic splitting for GitHub's per-asset release limit
* Release manifest and checksum assets
* Exact release restore instructions generated per backup
* Backup release retention workflow
* Public-repository friendly
* No dedicated backup infrastructure required

## Security model

The backup command created by `setup.sh` runs this stream on the backup server:

```text
mysqldump → PROCESS\_COMMAND → age → GitHub Actions runner
```

With trusted defaults such as:

```text
MYSQLDUMP\_CMD=mysqldump
PROCESS\_COMMAND=zstd -19
```

database contents are written to `stdout`, processed, encrypted by `age`, and only the encrypted stream is sent to GitHub Actions.

GitHub receives encrypted backup bytes only. The private `age` key is not required on the server or in GitHub Actions.

### Important guarantees

* Database contents are encrypted before leaving the backup server.
* GitHub Actions stores only encrypted backup assets.
* The SSH account is restricted to a single forced command.
* The Linux backup user has password-based login locked.
* The MySQL user is created specifically for backup operations.
* MySQL access is scoped to the selected database and host pattern.
* The MySQL backup password is passed to the backup command through standard input.
* The private `age` key is not required on the server or in GitHub Actions.
* SSH host identity is pinned through `SSH\_KNOWN\_HOSTS`; the workflow does not trust `ssh-keyscan` during backup execution.

> \[!IMPORTANT]
> If the private `age` key is lost, backups become unrecoverable.
>
> If the private `age` key is leaked, all backups encrypted with the corresponding public key should be considered compromised. Generate a new key pair and rotate `AGE\_PUBLIC\_KEY` immediately.

### Plaintext boundary and leak paths

The plaintext boundary is everything before `age` on the backup server.

`MYSQLDUMP\_CMD` and `PROCESS\_COMMAND` run before encryption and must be trusted.

|Path|Can expose database contents?|Criticality|Notes|
|-|-:|-:|-|
|`mysqldump stdout → PROCESS\_COMMAND → age stdout`|No, when commands are trusted|Low|This is the intended path. The runner receives the encrypted `age` output.|
|`mysqldump stderr`|Normally no|Medium|Diagnostic output is not encrypted and may appear in workflow logs. Normal `mysqldump` errors should not contain table data, but stderr is outside the encrypted stream.|
|`PROCESS\_COMMAND stderr`|Depends on command|High|Safe commands such as `zstd` should not print backup contents to stderr. A custom command must not write plaintext data to stderr.|
|Unsafe `PROCESS\_COMMAND`, for example duplicating input to stderr|Yes|Critical|Anything before `age` can leak plaintext if configured to print or copy the stream elsewhere.|
|Unsafe `MYSQLDUMP\_CMD` wrapper|Yes|Critical|A custom dump command can leak plaintext if it writes database contents to stderr, files, or the network.|
|Temporary MySQL credentials file in `/dev/shm`|No database dump; contains password|High|The backup command writes a temporary MySQL client config in memory-backed `/dev/shm` and removes it on exit. It contains the MySQL backup password, not the dump.|
|GitHub Release assets|No, unless private `age` key is compromised|Low|Release assets contain encrypted backup data.|
|Lost private `age` key|Backup cannot be decrypted|Critical|Backups become unrecoverable.|
|Leaked private `age` key|Existing encrypted backups may be decrypted|Critical|Treat all backups encrypted with that public key as compromised. Rotate `AGE\_PUBLIC\_KEY`.|
|Wrong `BACKUP\_USER` in workflow|No dump if forced command is not reached|Medium|The workflow must connect to the same Linux user that was configured by `setup.sh`.|
|Missing or bypassed forced SSH command|Depends on server configuration|High|The workflow is designed for forced-command SSH access. Do not use a normal shell account for backups.|
|Wrong `SSH\_KNOWN\_HOSTS` value|Backup fails before SSH login|Low|This is intended. Host key mismatch should stop the workflow.|

The project guarantees that the intended backup stream is encrypted before it reaches GitHub Actions. It does not make unsafe custom commands safe. Any command that runs before `age` is part of the trusted server-side plaintext zone.

## GitHub Release asset limits

Backups are uploaded as GitHub Release assets.

Each release asset must be smaller than 2 GiB. When the encrypted backup is larger than the per-asset limit, the workflow splits it into multiple smaller assets before upload.

A single GitHub Release can contain up to 1000 assets. The workflow stores one backup in one GitHub Release. It does not currently distribute a single backup across multiple releases.

In practice, very large backups will usually hit the available GitHub-hosted runner disk space before they hit the theoretical single-release asset capacity.

## Failure behavior

The backup workflow fails explicitly when:

* required configuration is missing;
* the pinned SSH host key is missing or invalid;
* the workflow cannot create GitHub Releases with `github.token`;
* the encrypted and processed backup is larger than the available disk space on the GitHub Actions runner;
* the backup would require more release assets than GitHub allows in a single release;
* SSH connection, forced command execution, or release upload fails.

The workflow does not silently skip oversized backups and does not report partial backup uploads as successful.

Releases are created as drafts first. If asset upload fails after draft release creation, the workflow attempts to delete the incomplete draft release and its tag.

The workflow also performs a small release permission preflight before starting the expensive backup stream. If `github.token` cannot create and delete releases, the workflow fails early instead of failing after a long backup.

## How it works

1. GitHub Actions validates configuration.
2. GitHub Actions verifies that `github.token` can create and delete releases.
3. GitHub Actions installs the pinned SSH known\_hosts entry from `SSH\_KNOWN\_HOSTS`.
4. GitHub Actions connects to the backup server using SSH.
5. A restricted Linux backup user executes a forced command.
6. The server reads the MySQL backup password from standard input.
7. `mysqldump` creates a database dump.
8. The dump stream is processed, for example compressed with `zstd`.
9. The processed stream is encrypted with `age` on the server.
10. GitHub Actions receives the encrypted stream only.
11. The runner writes the encrypted stream through `split`.
12. The workflow creates a manifest, checksums, and exact restore notes.
13. The workflow uploads the encrypted backup assets to a GitHub Release.
14. The cleanup workflow later deletes old matching backup releases according to retention settings.

At no point should GitHub receive unencrypted database contents when trusted dump and processing commands are used.

## Requirements

Install the required packages on the MySQL server:

```sh
apt update
apt install -y mysql-client zstd openssh-server curl
```

Install `age`:

```sh
AGE\_VERSION="1.2.1"

curl -fsSL \\
  "https://github.com/FiloSottile/age/releases/download/v${AGE\_VERSION}/age-v${AGE\_VERSION}-linux-amd64.tar.gz" \\
  -o age.tar.gz

tar -xzf age.tar.gz

install age/age /usr/local/bin/age
install age/age-keygen /usr/local/bin/age-keygen

rm -rf age age.tar.gz
```

## Setup process

Before running `setup.sh`, define the backup server, database, keys, pinned host key, and GitHub Actions configuration.

### 1\. Define server-side setup variables

These variables are used by `setup.sh`.

|Variable|Required|Default|Secret?|Description|
|-|-:|-|-:|-|
|`SSH\_PUBLIC\_KEY`|Yes|—|No|Public SSH key installed for the restricted backup user.|
|`AGE\_PUBLIC\_KEY`|Yes|—|No|Public `age` key used to encrypt backups.|
|`DB\_NAME`|Yes|—|No|MySQL database name to back up.|
|`MYSQL\_PASSWORD`|Yes|—|Yes|Password for the MySQL backup user. Also required by GitHub Actions.|
|`BACKUP\_USER`|No|`backup`|No|Linux user used for SSH backup access.|
|`BACKUP\_HOME`|No|`/home/$BACKUP\_USER`|No|Home directory of the Linux backup user.|
|`BACKUP\_COMMAND`|No|`/usr/local/sbin/github-mysql-backup.sh`|No|Path where the forced backup command is installed.|
|`MYSQL\_USER`|No|`backup`|No|MySQL user used for backup operations.|
|`MYSQL\_HOST\_PATTERN`|No|`localhost`|No|MySQL host pattern for the backup user.|
|`MYSQLDUMP\_CMD`|No|`mysqldump`|No|Command used to create the database dump. Runs before encryption and must be trusted.|
|`MYSQL\_CHARSET`|No|`utf8mb4`|No|MySQL client character set used during backup execution.|
|`MYSQL\_ADMIN\_CMD`|No|`mysql`|No|Command used by `setup.sh` to configure MySQL users and grants.|
|`PROCESS\_COMMAND`|No|`zstd -19`|No|Command used to process the dump stream before encryption. Runs before encryption and must be trusted.|

Common examples:

```text
MYSQL\_HOST\_PATTERN=172.18.%
MYSQLDUMP\_CMD=mysqldump --host 127.0.0.1 --port 3306
MYSQL\_ADMIN\_CMD=mysql --host 127.0.0.1 --port 3306 --user root -p
PROCESS\_COMMAND=zstd -19
```

### 2\. Generate encryption keys

Generate an `age` key pair on your local machine:

```sh
age-keygen -o backup-key.txt
```

Pass the public key to `setup.sh` as `AGE\_PUBLIC\_KEY`.

Keep the private key securely, separately from the repository. Prefer keeping multiple offline copies. If it is lost, existing backups cannot be decrypted.

Do not store the private `age` key in GitHub repository secrets, on the MySQL server, or in the repository.

### 3\. Generate SSH keys

Generate an SSH key pair for GitHub Actions backup access:

```sh
ssh-keygen -t ed25519 -f id\_ed25519\_backup
```

Pass the public SSH key to `setup.sh` as `SSH\_PUBLIC\_KEY`.

Store the private SSH key as the `SSH\_PRIVATE\_KEY` GitHub repository secret.

### 4\. Pin the SSH host key

Create a known\_hosts entry from a trusted machine:

```sh
SSH\_HOST='example.com'
SSH\_PORT='22'

ssh-keyscan -p "$SSH\_PORT" -H "$SSH\_HOST" > ssh\_known\_hosts
ssh-keygen -lf ssh\_known\_hosts
```

Verify the printed fingerprint out of band, for example against your hosting provider console or a trusted existing SSH session.

Store the full contents of `ssh\_known\_hosts` as `SSH\_KNOWN\_HOSTS` in either:

* GitHub repository secret `SSH\_KNOWN\_HOSTS`; or
* GitHub repository variable `SSH\_KNOWN\_HOSTS`.

Secret takes priority over variable. The host key itself is public key material, but storing it as a secret can hide server metadata.

The backup workflow does not run `ssh-keyscan` during backup execution. A host key mismatch stops the workflow before SSH login.

### 5\. Generate the MySQL backup password

Generate a password for the MySQL backup user.

Pass this password to `setup.sh` as `MYSQL\_PASSWORD`.

Store the same password as the `MYSQL\_PASSWORD` GitHub repository secret. GitHub Actions sends it to the backup command through standard input.

### 6\. Define GitHub Actions secrets

Secrets are used for sensitive values and for operational metadata that you prefer not to expose.

|Secret|Required|Description|
|-|-:|-|
|`SSH\_HOST`|Yes|Hostname or IP address of the backup server.|
|`SSH\_PRIVATE\_KEY`|Yes|Private SSH key corresponding to the public key passed as `SSH\_PUBLIC\_KEY`.|
|`SSH\_KNOWN\_HOSTS`|Yes, unless using variable|Pinned OpenSSH known\_hosts entry for the backup server. Can also be stored as a repository variable.|
|`MYSQL\_PASSWORD`|Yes|Password of the MySQL backup user.|
|`SSH\_PORT`|No|SSH port of the backup server. Required only when not using port `22`. Can also be stored as a repository variable.|
|`BACKUP\_USER`|No|Linux user used for SSH backup access. Can also be stored as a repository variable.|

`SSH\_PORT`, `BACKUP\_USER`, and `SSH\_KNOWN\_HOSTS` are not credentials, but they can be stored as secrets if you prefer to hide operational metadata. When both a secret and a variable are set for the same name, the workflow uses the secret first.

The SSH private key and MySQL password must never be committed to the repository.

### 7\. Define GitHub Actions variables

Repository variables are used for non-sensitive workflow configuration.

|Variable|Required|Default|Description|
|-|-:|-|-|
|`SSH\_KNOWN\_HOSTS`|Yes, unless using secret|—|Pinned OpenSSH known\_hosts entry for the backup server. Secret wins.|
|`BACKUP\_USER`|No|`backup`|Linux user used for SSH backup access. Must match the `BACKUP\_USER` used during `setup.sh`. Secret wins.|
|`BACKUP\_NAME`|No|`mysql`|Human-readable backup name used in release titles and metadata.|
|`RELEASE\_PREFIX`|No|`mysql-backup`|Prefix used for GitHub Release tags. The cleanup workflow uses the same prefix.|
|`ASSET\_PREFIX`|No|`mysql-backup`|Prefix used for uploaded release asset names.|
|`SPLIT\_SIZE\_BYTES`|No|`2000000000`|Split size for release assets. Must be lower than 2 GiB.|
|`SSH\_PORT`|No|`22`|SSH port. Can be stored as a secret instead if preferred. Secret wins.|
|`RESTORE\_DECODE\_COMMAND`|No|`zstd -d -c`|Command shown in release restore instructions to decode the processed stream after `age -d`.|
|`RESTORE\_MYSQL\_COMMAND`|No|`mysql`|Command shown in release restore instructions to import the decoded SQL file. Do not include passwords in this variable.|
|`RETENTION\_KEEP\_LAST`|No|`30`|Keep at least this many newest matching backup releases. Used by `cl-backup.yml`.|
|`RETENTION\_MIN\_AGE\_DAYS`|No|`30`|Never delete matching backup releases newer than this many days. Used by `cl-backup.yml`.|
|`RETENTION\_DRY\_RUN`|No|`false`|If `true`, cleanup prints what it would delete without deleting releases.|

The workflows use GitHub's automatically generated `GITHUB\_TOKEN` through `github.token`. You do not need to create a personal access token. The workflows grant it `contents: write` permission to create and delete releases and tags.

## GitHub workflow permissions

The backup and cleanup workflows require:

```yaml
permissions:
  contents: write
```

If the backup fails with:

```text
HTTP 403: Resource not accessible by integration
```

check:

1. The workflow file contains `permissions: contents: write`.
2. Repository settings allow workflows to use write permissions:
`Settings → Actions → General → Workflow permissions`.
3. The workflow is running in the target repository, not as an untrusted fork pull request workflow.

The backup workflow performs a release permission preflight before starting the backup stream. This is intended to catch permission problems early.

## Installation

Run the setup script on the MySQL server as `root`.

### Basic installation

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH\_PUBLIC\_KEY='ssh-ed25519 AAAA...' \\
AGE\_PUBLIC\_KEY='age1...' \\
DB\_NAME='my\_database' \\
MYSQL\_PASSWORD='strong-backup-password' \\
./setup.sh

rm setup.sh
```

### Advanced installation

All configurable setup values can be supplied through environment variables:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/main/setup.sh -o setup.sh
chmod +x setup.sh

BACKUP\_USER='backup' \\
BACKUP\_HOME='/home/backup' \\
BACKUP\_COMMAND='/usr/local/sbin/github-mysql-backup.sh' \\
SSH\_PUBLIC\_KEY='ssh-ed25519 AAAA...' \\
AGE\_PUBLIC\_KEY='age1...' \\
DB\_NAME='my\_database' \\
MYSQL\_USER='backup' \\
MYSQL\_PASSWORD='strong-backup-password' \\
MYSQL\_HOST\_PATTERN='localhost' \\
MYSQLDUMP\_CMD='mysqldump' \\
MYSQL\_CHARSET='utf8mb4' \\
MYSQL\_ADMIN\_CMD='mysql' \\
PROCESS\_COMMAND='zstd -19' \\
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

SSH\_PUBLIC\_KEY='ssh-ed25519 AAAA...' \\
AGE\_PUBLIC\_KEY='age1...' \\
DB\_NAME='my\_database' \\
MYSQL\_PASSWORD='strong-backup-password' \\
MYSQL\_HOST\_PATTERN='172.18.%' \\
./setup.sh

rm setup.sh
```

### Custom MySQL administration command

For systems where MySQL administration requires a custom command:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH\_PUBLIC\_KEY='ssh-ed25519 AAAA...' \\
AGE\_PUBLIC\_KEY='age1...' \\
DB\_NAME='my\_database' \\
MYSQL\_PASSWORD='strong-backup-password' \\
MYSQL\_ADMIN\_CMD='sudo mysql' \\
./setup.sh

rm setup.sh
```

### Custom dump command

For `mysqldump` with additional connection options:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH\_PUBLIC\_KEY='ssh-ed25519 AAAA...' \\
AGE\_PUBLIC\_KEY='age1...' \\
DB\_NAME='my\_database' \\
MYSQL\_PASSWORD='strong-backup-password' \\
MYSQLDUMP\_CMD='mysqldump --host 127.0.0.1 --port 3306' \\
./setup.sh

rm setup.sh
```

### Custom processing command

For custom dump stream processing before encryption:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh -o setup.sh
chmod +x setup.sh

SSH\_PUBLIC\_KEY='ssh-ed25519 AAAA...' \\
AGE\_PUBLIC\_KEY='age1...' \\
DB\_NAME='my\_database' \\
MYSQL\_PASSWORD='strong-backup-password' \\
PROCESS\_COMMAND='zstd -10 -T0' \\
./setup.sh

rm setup.sh
```

If the custom processing command changes the restore decoder, update `RESTORE\_DECODE\_COMMAND` in repository variables.

Examples:

```text
PROCESS\_COMMAND=zstd -10 -T0       RESTORE\_DECODE\_COMMAND=zstd -d -c
PROCESS\_COMMAND=gzip -9            RESTORE\_DECODE\_COMMAND=gzip -d -c
PROCESS\_COMMAND=cat                RESTORE\_DECODE\_COMMAND=cat
```

## MySQL permissions

The setup script grants the MySQL backup user permissions on the selected database:

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT
ON `<DB\_NAME>`.\* TO '<MYSQL\_USER>'@'<MYSQL\_HOST\_PATTERN>';
```

It also grants the global `RELOAD` permission:

```sql
GRANT RELOAD ON \*.\* TO '<MYSQL\_USER>'@'<MYSQL\_HOST\_PATTERN>';
```

`LOCK TABLES` is intentionally not granted. The backup command uses `--single-transaction`.

`PROCESS` is intentionally not granted. The backup command uses `--no-tablespaces`, so `mysqldump` should not require global `PROCESS` for tablespace metadata.

## Backup workflow

Place the backup workflow at:

```text
.github/workflows/mk-backup.yml
```

It runs:

* manually through `workflow\_dispatch`;
* daily at `03:00 UTC` by default.

Main workflow steps:

```text
Validate configuration
Validate GitHub Release permissions
Create encrypted backup assets
Create GitHub Release
Write workflow summary
```

The long `Create encrypted backup assets` step contains grouped logs:

```text
SSH setup
Backup plan
Encrypted backup stream
Split output
Asset preparation
Size and checksum
Manifest and checksums
Prepared assets
```

The encrypted stream progress is reported by `dd status=progress` after server-side `age` encryption.

## Cleanup workflow and retention

Place the cleanup workflow at:

```text
.github/workflows/cl-backup.yml
```

It runs:

* manually through `workflow\_dispatch`;
* daily at `05:30 UTC` by default.

Retention is based on published GitHub Releases whose tags start with:

```text
<RELEASE\_PREFIX>-
```

Defaults:

```text
RETENTION\_KEEP\_LAST=30
RETENTION\_MIN\_AGE\_DAYS=30
RETENTION\_DRY\_RUN=false
```

A backup release is deleted only when both are true:

* it is not among the newest `RETENTION\_KEEP\_LAST` matching releases;
* it is at least `RETENTION\_MIN\_AGE\_DAYS` old.

Draft releases are ignored by cleanup.

The cleanup workflow shares the same concurrency group as the backup workflow:

```yaml
concurrency:
  group: mysql-crypto-backup
  cancel-in-progress: false
```

This prevents cleanup from running at the same time as a backup.

To test cleanup without deleting anything:

```text
RETENTION\_DRY\_RUN=true
```

## Restore

Every backup release contains:

```text
<ASSET\_PREFIX>-<STAMP>.age
<ASSET\_PREFIX>-<STAMP>.manifest.json
<ASSET\_PREFIX>-<STAMP>.sha256
```

or, for split backups:

```text
<ASSET\_PREFIX>-<STAMP>.age.part-0000
<ASSET\_PREFIX>-<STAMP>.age.part-0001
...
<ASSET\_PREFIX>-<STAMP>.manifest.json
<ASSET\_PREFIX>-<STAMP>.sha256
```

The release notes contain exact restore commands for that backup and mode.

The manifest also contains commands intended to be run after all release assets are downloaded into the current directory.

### Manual restore pattern

For a single-file backup:

```sh
sha256sum -c mysql-backup-YYYYMMDDTHHMMSSZ.sha256
printf '%s  %s\\n' '<assembled-sha256-from-manifest>' 'mysql-backup-YYYYMMDDTHHMMSSZ.age' | sha256sum -c -
age -d -i backup-key.txt < mysql-backup-YYYYMMDDTHHMMSSZ.age > mysql-backup-YYYYMMDDTHHMMSSZ.age.processed
zstd -d -c < mysql-backup-YYYYMMDDTHHMMSSZ.age.processed > mysql-backup-YYYYMMDDTHHMMSSZ.age.sql
mysql < mysql-backup-YYYYMMDDTHHMMSSZ.age.sql
```

For a split backup:

```sh
sha256sum -c mysql-backup-YYYYMMDDTHHMMSSZ.sha256
cat mysql-backup-YYYYMMDDTHHMMSSZ.age.part-\* > mysql-backup-YYYYMMDDTHHMMSSZ.age
printf '%s  %s\\n' '<assembled-sha256-from-manifest>' 'mysql-backup-YYYYMMDDTHHMMSSZ.age' | sha256sum -c -
age -d -i backup-key.txt < mysql-backup-YYYYMMDDTHHMMSSZ.age > mysql-backup-YYYYMMDDTHHMMSSZ.age.processed
zstd -d -c < mysql-backup-YYYYMMDDTHHMMSSZ.age.processed > mysql-backup-YYYYMMDDTHHMMSSZ.age.sql
mysql < mysql-backup-YYYYMMDDTHHMMSSZ.age.sql
```

If `PROCESS\_COMMAND` is not `zstd`, use the matching local decode command instead of `zstd -d -c` and set `RESTORE\_DECODE\_COMMAND` so new release notes are correct.

Inspect the decoded SQL before importing it into a production database.

## Configuration reference

|Name|Required|Default|Used by|Store as GitHub secret|Description|
|-|-:|-|-|-:|-|
|`SSH\_HOST`|Yes|—|GitHub Actions|Yes|Hostname or IP address of the backup server.|
|`SSH\_PORT`|No|`22`|GitHub Actions|Optional|SSH port of the backup server. Secret takes priority over repository variable.|
|`SSH\_PRIVATE\_KEY`|Yes|—|GitHub Actions|Yes|Private SSH key used by GitHub Actions to connect to the backup server.|
|`SSH\_PUBLIC\_KEY`|Yes|—|`setup.sh`|No|Public SSH key installed for the restricted backup user.|
|`SSH\_KNOWN\_HOSTS`|Yes|—|GitHub Actions|Optional|Pinned OpenSSH known\_hosts entry. Secret takes priority over repository variable.|
|`AGE\_PUBLIC\_KEY`|Yes|—|`setup.sh`|No|Public `age` key used to encrypt backups.|
|`DB\_NAME`|Yes|—|`setup.sh`|No|MySQL database name to back up.|
|`BACKUP\_USER`|No|`backup`|`setup.sh`, GitHub Actions|Optional|Linux user used for SSH backup access. Must match in setup and workflow. Secret takes priority.|
|`BACKUP\_HOME`|No|`/home/$BACKUP\_USER`|`setup.sh`|No|Home directory of the Linux backup user.|
|`BACKUP\_COMMAND`|No|`/usr/local/sbin/github-mysql-backup.sh`|`setup.sh`|No|Path where the forced backup command is installed.|
|`MYSQL\_USER`|No|`backup`|`setup.sh`|No|MySQL user used for backup operations.|
|`MYSQL\_PASSWORD`|Yes|—|`setup.sh`, GitHub Actions|Yes|Password for the MySQL backup user.|
|`MYSQL\_HOST\_PATTERN`|No|`localhost`|`setup.sh`|No|MySQL host pattern for the backup user.|
|`MYSQLDUMP\_CMD`|No|`mysqldump`|`setup.sh`|No|Command used to create the database dump. Runs before encryption and must be trusted.|
|`MYSQL\_CHARSET`|No|`utf8mb4`|`setup.sh`|No|MySQL client character set used during backup execution.|
|`MYSQL\_ADMIN\_CMD`|No|`mysql`|`setup.sh`|No|Command used to configure MySQL users and grants.|
|`PROCESS\_COMMAND`|No|`zstd -19`|`setup.sh`|No|Command used to process the dump stream before encryption. Runs before encryption and must be trusted.|
|`BACKUP\_NAME`|No|`mysql`|GitHub Actions|No|Human-readable backup name used in release titles and metadata.|
|`RELEASE\_PREFIX`|No|`mysql-backup`|GitHub Actions|No|Prefix used for backup release tags and cleanup matching.|
|`ASSET\_PREFIX`|No|`mysql-backup`|GitHub Actions|No|Prefix used for uploaded release asset names.|
|`SPLIT\_SIZE\_BYTES`|No|`2000000000`|GitHub Actions|No|Split size for release assets. Must be lower than 2 GiB.|
|`RESTORE\_DECODE\_COMMAND`|No|`zstd -d -c`|GitHub Actions|No|Command written into release notes to decode the processed stream after decryption.|
|`RESTORE\_MYSQL\_COMMAND`|No|`mysql`|GitHub Actions|No|Command written into release notes to import the SQL file. Do not include passwords.|
|`RETENTION\_KEEP\_LAST`|No|`30`|Cleanup workflow|No|Keep at least this many newest matching backup releases.|
|`RETENTION\_MIN\_AGE\_DAYS`|No|`30`|Cleanup workflow|No|Never delete matching backup releases newer than this many days.|
|`RETENTION\_DRY\_RUN`|No|`false`|Cleanup workflow|No|Print deletion plan without deleting when set to `true`.|



