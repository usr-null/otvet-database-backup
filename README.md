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
* GitHub Actions stores only encrypted backup assets.
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

### Plaintext boundary and leak paths

The backup command created by `setup.sh` runs this stream on the backup server:

```text
mysqldump → PROCESS_COMMAND → age → GitHub Actions runner
```

With trusted defaults such as:

```text
MYSQLDUMP_CMD=mysqldump
PROCESS_COMMAND=zstd -19
```

database contents are written to `stdout`, processed, encrypted by `age`, and only the encrypted stream is sent to GitHub Actions.

The plaintext boundary is everything before `age`.

`MYSQLDUMP_CMD` and `PROCESS_COMMAND` run before encryption and must be trusted.

| Path                                                              |               Can expose database contents? | Criticality | Notes                                                                                                                                                                    |
| ----------------------------------------------------------------- | ------------------------------------------: | ----------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `mysqldump stdout → PROCESS_COMMAND → age stdout`                 |               No, when commands are trusted |         Low | This is the intended path. The runner receives the encrypted `age` output.                                                                                               |
| `mysqldump stderr`                                                |                                 Normally no |      Medium | Diagnostic output is not encrypted and may appear in workflow logs. Normal `mysqldump` errors should not contain table data, but stderr is outside the encrypted stream. |
| `PROCESS_COMMAND stderr`                                          |                          Depends on command |        High | Safe commands such as `zstd` should not print backup contents to stderr. A custom command must not write plaintext data to stderr.                                       |
| Unsafe `PROCESS_COMMAND`, for example duplicating input to stderr |                                         Yes |    Critical | Anything before `age` can leak plaintext if configured to print or copy the stream elsewhere.                                                                            |
| Unsafe `MYSQLDUMP_CMD` wrapper                                    |                                         Yes |    Critical | A custom dump command can leak plaintext if it writes database contents to stderr, files, or the network.                                                                |
| Temporary MySQL credentials file in `/dev/shm`                    |         No database dump; contains password |        High | The backup command writes a temporary MySQL client config in memory-backed `/dev/shm` and removes it on exit. It contains the MySQL backup password, not the dump.       |
| GitHub Release assets                                             | No, unless private `age` key is compromised |         Low | Release assets contain encrypted backup data.                                                                                                                            |
| Lost private `age` key                                            |                  Backup cannot be decrypted |    Critical | Backups become unrecoverable.                                                                                                                                            |
| Leaked private `age` key                                          | Existing encrypted backups may be decrypted |    Critical | Treat all backups encrypted with that public key as compromised. Rotate `AGE_PUBLIC_KEY`.                                                                                |
| Wrong `BACKUP_USER` in workflow                                   |    No dump if forced command is not reached |      Medium | The workflow must connect to the same Linux user that was configured by `setup.sh`.                                                                                      |
| Missing or bypassed forced SSH command                            |             Depends on server configuration |        High | The workflow is designed for forced-command SSH access. Do not use a normal shell account for backups.                                                                   |

The project guarantees that the intended backup stream is encrypted before it reaches GitHub Actions. It does not make unsafe custom commands safe. Any command that runs before `age` is part of the trusted server-side plaintext zone.

### GitHub Release asset limits

Backups are uploaded as GitHub Release assets.

Each release asset must be smaller than 2 GiB. When the encrypted backup is larger than the per-asset limit, the workflow attempts to split it into multiple smaller assets before upload.

A single GitHub Release can contain up to 1000 assets. This gives a practical single-release capacity of slightly less than 2000 GiB when a backup is split into release assets.

The workflow stores one backup in one GitHub Release. It does not currently distribute a single backup across multiple releases.

Splitting one backup across multiple GitHub Releases is possible, but it is not implemented yet. In practice, this is unlikely to matter for public GitHub-hosted runners, because such large backups would normally exceed the available runner disk space before reaching the practical single-release asset capacity.

### Failure behavior

The workflow fails explicitly and writes an error to the logs when:

* the encrypted and processed backup is larger than the available disk space on the GitHub Actions runner;
* the backup would require more release assets than GitHub allows in a single release;
* SSH connection, forced command execution, or release upload fails.

The workflow does not silently skip oversized backups and does not report partial backup uploads as successful.

Releases are created as drafts first. If asset upload fails after draft release creation, the workflow attempts to delete the incomplete draft release and its tag.

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

At no point should GitHub receive unencrypted database contents when trusted dump and processing commands are used.

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

Before running `setup.sh`, define the backup server, database, keys, and GitHub Actions configuration.

### 1. Define server-side setup variables

These variables are used by `setup.sh`.

| Variable             | Required | Default                                  | Secret? | Description                                                                                            |
| -------------------- | -------: | ---------------------------------------- | ------: | ------------------------------------------------------------------------------------------------------ |
| `SSH_PUBLIC_KEY`     |      Yes | —                                        |      No | Public SSH key installed for the restricted backup user.                                               |
| `AGE_PUBLIC_KEY`     |      Yes | —                                        |      No | Public `age` key used to encrypt backups.                                                              |
| `DB_NAME`            |      Yes | —                                        |      No | MySQL database name to back up.                                                                        |
| `MYSQL_PASSWORD`     |      Yes | —                                        |     Yes | Password for the MySQL backup user. Also required by GitHub Actions.                                   |
| `BACKUP_USER`        |       No | `backup`                                 |      No | Linux user used for SSH backup access.                                                                 |
| `BACKUP_HOME`        |       No | `/home/$BACKUP_USER`                     |      No | Home directory of the Linux backup user.                                                               |
| `BACKUP_COMMAND`     |       No | `/usr/local/sbin/github-mysql-backup.sh` |      No | Path where the forced backup command is installed.                                                     |
| `MYSQL_USER`         |       No | `backup`                                 |      No | MySQL user used for backup operations.                                                                 |
| `MYSQL_HOST_PATTERN` |       No | `localhost`                              |      No | MySQL host pattern for the backup user.                                                                |
| `MYSQLDUMP_CMD`      |       No | `mysqldump`                              |      No | Command used to create the database dump. Runs before encryption and must be trusted.                  |
| `MYSQL_CHARSET`      |       No | `utf8mb4`                                |      No | MySQL client character set used during backup execution.                                               |
| `MYSQL_ADMIN_CMD`    |       No | `mysql`                                  |      No | Command used by `setup.sh` to configure MySQL users and grants.                                        |
| `PROCESS_COMMAND`    |       No | `zstd -19`                               |      No | Command used to process the dump stream before encryption. Runs before encryption and must be trusted. |

Common examples:

```text
MYSQL_HOST_PATTERN=172.18.%
MYSQLDUMP_CMD=mysqldump --host 127.0.0.1 --port 3306
MYSQL_ADMIN_CMD=mysql --host 127.0.0.1 --port 3306 --user root -p
PROCESS_COMMAND=zstd -19
```

### 2. Generate encryption keys

Generate an `age` key pair on your local machine:

```sh
age-keygen -o backup-key.txt
```

Pass the public key to `setup.sh` as `AGE_PUBLIC_KEY`.

Keep the private key securely, separately from the repository. Prefer keeping an offline copy. If it is lost, existing backups cannot be decrypted.

Do not store the private `age` key in GitHub repository secrets.

### 3. Generate SSH keys

Generate an SSH key pair for GitHub Actions backup access:

```sh
ssh-keygen -t ed25519 -f id_ed25519_backup
```

Pass the public SSH key to `setup.sh` as `SSH_PUBLIC_KEY`.

Store the private SSH key as the `SSH_PRIVATE_KEY` GitHub repository secret.

### 4. Generate the MySQL backup password

Generate a password for the MySQL backup user.

Pass this password to `setup.sh` as `MYSQL_PASSWORD`.

Store the same password as the `MYSQL_PASSWORD` GitHub repository secret. GitHub Actions sends it to the backup command through standard input.

### 5. Define GitHub Actions secrets

Secrets are used for sensitive values.

| Secret            | Required | Description                                                                                                         |
| ----------------- | -------: | ------------------------------------------------------------------------------------------------------------------- |
| `SSH_HOST`        |      Yes | Hostname or IP address of the backup server.                                                                        |
| `SSH_PRIVATE_KEY` |      Yes | Private SSH key corresponding to the public key passed as `SSH_PUBLIC_KEY`.                                         |
| `MYSQL_PASSWORD`  |      Yes | Password of the MySQL backup user.                                                                                  |
| `SSH_PORT`        |       No | SSH port of the backup server. Required only when not using port `22`. Can also be stored as a repository variable. |

The SSH private key and MySQL password must never be committed to the repository.

### 6. Define GitHub Actions variables

Repository variables are used for non-sensitive workflow configuration.

| Variable           | Required | Default        | Description                                                                                 |
| ------------------ | -------: | -------------- | ------------------------------------------------------------------------------------------- |
| `BACKUP_USER`      |       No | `backup`       | Linux user used for SSH backup access. Must match the `BACKUP_USER` used during `setup.sh`. |
| `BACKUP_NAME`      |       No | `mysql`        | Human-readable backup name used in release titles and metadata.                             |
| `RELEASE_PREFIX`   |       No | `mysql-backup` | Prefix used for GitHub Release tags.                                                        |
| `ASSET_PREFIX`     |       No | `mysql-backup` | Prefix used for uploaded release asset names.                                               |
| `SPLIT_SIZE_BYTES` |       No | `2000000000`   | Split size for release assets. Must be lower than 2 GiB.                                    |
| `SSH_PORT`         |       No | `22`           | SSH port. Can be stored as a secret instead if preferred.                                   |

The workflow also uses GitHub's automatically generated `GITHUB_TOKEN` through `github.token`. You do not need to create a personal access token. The workflow must grant it `contents: write` permission to create releases and upload release assets.

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

## GitHub Actions workflow

Create:

```text
.github/workflows/mysql-backup.yml
```

```yaml
name: Encrypted MySQL backup

on:
  workflow_dispatch:
  schedule:
    - cron: "0 3 * * *"

permissions:
  contents: write

concurrency:
  group: mysql-crypto-backup
  cancel-in-progress: false

env:
  SSH_HOST: ${{ secrets.SSH_HOST }}
  SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
  MYSQL_PASSWORD: ${{ secrets.MYSQL_PASSWORD }}

  SSH_PORT: ${{ secrets.SSH_PORT || vars.SSH_PORT || '22' }}
  BACKUP_USER: ${{ vars.BACKUP_USER || 'backup' }}

  BACKUP_NAME: ${{ vars.BACKUP_NAME || 'mysql' }}
  RELEASE_PREFIX: ${{ vars.RELEASE_PREFIX || 'mysql-backup' }}
  ASSET_PREFIX: ${{ vars.ASSET_PREFIX || 'mysql-backup' }}
  SPLIT_SIZE_BYTES: ${{ vars.SPLIT_SIZE_BYTES || '2000000000' }}
  MAX_RELEASE_ASSETS: "1000"

jobs:
  backup:
    name: Create encrypted backup release
    runs-on: ubuntu-latest
    timeout-minutes: 360

    steps:
      - name: Validate configuration
        shell: bash
        run: |
          set -euo pipefail

          require_value() {
            local name="$1"
            local value="${!name:-}"

            if [ -z "$value" ]; then
              echo "::error::Missing required value: $name"
              exit 1
            fi
          }

          require_value SSH_HOST
          require_value SSH_PRIVATE_KEY
          require_value MYSQL_PASSWORD
          require_value BACKUP_USER
          require_value BACKUP_NAME
          require_value RELEASE_PREFIX
          require_value ASSET_PREFIX
          require_value SPLIT_SIZE_BYTES
          require_value MAX_RELEASE_ASSETS

          case "$SSH_PORT" in
            ''|*[!0-9]*)
              echo "::error::SSH_PORT must be numeric"
              exit 1
              ;;
          esac

          case "$SPLIT_SIZE_BYTES" in
            ''|*[!0-9]*)
              echo "::error::SPLIT_SIZE_BYTES must be numeric"
              exit 1
              ;;
          esac

          case "$MAX_RELEASE_ASSETS" in
            ''|*[!0-9]*)
              echo "::error::MAX_RELEASE_ASSETS must be numeric"
              exit 1
              ;;
          esac

          if [ "$SPLIT_SIZE_BYTES" -le 0 ]; then
            echo "::error::SPLIT_SIZE_BYTES must be greater than zero"
            exit 1
          fi

          if [ "$SPLIT_SIZE_BYTES" -ge 2147483648 ]; then
            echo "::error::SPLIT_SIZE_BYTES must be lower than 2 GiB"
            exit 1
          fi

          if [ "$MAX_RELEASE_ASSETS" -le 2 ]; then
            echo "::error::MAX_RELEASE_ASSETS must be greater than 2 because manifest and checksum assets are also uploaded"
            exit 1
          fi

      - name: Create encrypted backup assets
        id: backup
        shell: bash
        run: |
          set -Eeuo pipefail

          STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"

          WORKDIR="$RUNNER_TEMP/mysql-crypto-backup"
          SSH_DIR="$WORKDIR/ssh"
          PARTS_DIR="$WORKDIR/parts"
          ASSET_DIR="$WORKDIR/assets"

          mkdir -p "$SSH_DIR" "$PARTS_DIR" "$ASSET_DIR"
          chmod 700 "$SSH_DIR"

          SSH_KEY_FILE="$SSH_DIR/id_ed25519_backup"
          KNOWN_HOSTS_FILE="$SSH_DIR/known_hosts"

          printf '%s\n' "$SSH_PRIVATE_KEY" | tr -d '\r' > "$SSH_KEY_FILE"
          chmod 600 "$SSH_KEY_FILE"

          echo "Collecting SSH host key..."
          if ! ssh-keyscan -p "$SSH_PORT" -H "$SSH_HOST" >> "$KNOWN_HOSTS_FILE" 2>/dev/null; then
            echo "::error::Unable to collect SSH host key from backup server"
            exit 1
          fi

          chmod 600 "$KNOWN_HOSTS_FILE"

          TAG="${RELEASE_PREFIX}-${STAMP}"
          RELEASE_TITLE="${BACKUP_NAME} backup ${STAMP}"
          BACKUP_FILE="${ASSET_PREFIX}-${STAMP}.age"
          PART_PREFIX="$PARTS_DIR/${BACKUP_FILE}.part-"

          echo "Starting encrypted backup stream..."
          echo "Runner free space before backup:"
          df -h "$RUNNER_TEMP"

          if ! printf '%s\n' "$MYSQL_PASSWORD" \
            | ssh \
                -T \
                -p "$SSH_PORT" \
                -i "$SSH_KEY_FILE" \
                -o BatchMode=yes \
                -o IdentitiesOnly=yes \
                -o StrictHostKeyChecking=yes \
                -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
                "${BACKUP_USER}@${SSH_HOST}" \
                -- mysql-crypto-backup \
            | split -d -a 4 -b "$SPLIT_SIZE_BYTES" - "$PART_PREFIX"; then

            echo "::error::Backup stream failed. The server command may have failed, SSH may have failed, or the runner disk may be full."
            echo "Runner free space after failure:"
            df -h "$RUNNER_TEMP"
            exit 1
          fi

          PART_COUNT="$(find "$PARTS_DIR" -maxdepth 1 -type f -name "${BACKUP_FILE}.part-*" | wc -l | tr -d ' ')"

          if [ "$PART_COUNT" -eq 0 ]; then
            echo "::error::Backup stream produced no output"
            exit 1
          fi

          if [ "$PART_COUNT" -eq 1 ]; then
            MODE="single-file"
            ONLY_PART="$(find "$PARTS_DIR" -maxdepth 1 -type f -name "${BACKUP_FILE}.part-*")"
            mv "$ONLY_PART" "$ASSET_DIR/$BACKUP_FILE"
            UPLOAD_ASSET_COUNT=3
          else
            MODE="split"
            while IFS= read -r -d '' part; do
              mv "$part" "$ASSET_DIR/$(basename "$part")"
            done < <(find "$PARTS_DIR" -maxdepth 1 -type f -name "${BACKUP_FILE}.part-*" -print0 | sort -z)

            UPLOAD_ASSET_COUNT="$((PART_COUNT + 2))"
          fi

          if [ "$UPLOAD_ASSET_COUNT" -gt "$MAX_RELEASE_ASSETS" ]; then
            echo "::error::Backup requires $UPLOAD_ASSET_COUNT release assets, but the configured single-release limit is $MAX_RELEASE_ASSETS"
            echo "::error::This workflow does not split one backup across multiple GitHub Releases"
            exit 1
          fi

          if [ "$MODE" = "single-file" ]; then
            TOTAL_SIZE_BYTES="$(stat -c '%s' "$ASSET_DIR/$BACKUP_FILE")"
            ORIGINAL_SHA256="$(sha256sum "$ASSET_DIR/$BACKUP_FILE" | awk '{print $1}')"
          else
            TOTAL_SIZE_BYTES="$(find "$ASSET_DIR" -maxdepth 1 -type f -name "${BACKUP_FILE}.part-*" -printf '%s\n' | awk '{s += $1} END {print s + 0}')"
            ORIGINAL_SHA256="$(cat "$ASSET_DIR"/"${BACKUP_FILE}".part-* | sha256sum | awk '{print $1}')"
          fi

          MANIFEST_NAME="${ASSET_PREFIX}-${STAMP}.manifest.json"
          CHECKSUMS_NAME="${ASSET_PREFIX}-${STAMP}.sha256"
          MANIFEST_PATH="$ASSET_DIR/$MANIFEST_NAME"
          CHECKSUMS_PATH="$ASSET_DIR/$CHECKSUMS_NAME"
          NOTES_PATH="$WORKDIR/release-notes.md"

          export ASSET_DIR
          export MANIFEST_PATH
          export MODE
          export STAMP
          export TAG
          export BACKUP_NAME
          export BACKUP_FILE
          export SPLIT_SIZE_BYTES
          export TOTAL_SIZE_BYTES
          export ORIGINAL_SHA256
          export PART_COUNT
          export MANIFEST_NAME
          export CHECKSUMS_NAME

          python3 - <<'PY'
          import json
          import os
          from pathlib import Path

          asset_dir = Path(os.environ["ASSET_DIR"])

          backup_assets = sorted(
              p.name
              for p in asset_dir.iterdir()
              if p.is_file()
          )

          mode = os.environ["MODE"]
          backup_file = os.environ["BACKUP_FILE"]

          if mode == "single-file":
              restore_commands = [
                  f"age -d -i backup-key.txt < {backup_file} > backup.processed"
              ]
          else:
              restore_commands = [
                  f"cat {backup_file}.part-* > {backup_file}",
                  f"age -d -i backup-key.txt < {backup_file} > backup.processed"
              ]

          manifest = {
              "schema": "mysql-crypto-backup-manifest/v1",
              "created_at_utc": os.environ["STAMP"],
              "tag": os.environ["TAG"],
              "backup_name": os.environ["BACKUP_NAME"],
              "mode": mode,
              "encrypted_backup": {
                  "assembled_filename": backup_file,
                  "size_bytes": int(os.environ["TOTAL_SIZE_BYTES"]),
                  "sha256": os.environ["ORIGINAL_SHA256"],
                  "split_size_bytes": (
                      int(os.environ["SPLIT_SIZE_BYTES"])
                      if mode == "split"
                      else None
                  ),
                  "part_count": int(os.environ["PART_COUNT"]),
                  "assets": backup_assets
              },
              "metadata_assets": {
                  "manifest": os.environ["MANIFEST_NAME"],
                  "checksums": os.environ["CHECKSUMS_NAME"]
              },
              "restore": {
                  "output_after_age_decrypt": "backup.processed",
                  "commands": restore_commands
              }
          }

          with open(os.environ["MANIFEST_PATH"], "w", encoding="utf-8") as f:
              json.dump(manifest, f, indent=2)
              f.write("\n")
          PY

          TMP_CHECKSUMS="$WORKDIR/checksums.tmp"

          (
            cd "$ASSET_DIR"
            find . -maxdepth 1 -type f -printf '%f\n' \
              | sort \
              | while IFS= read -r file; do
                  sha256sum "$file"
                done
          ) > "$TMP_CHECKSUMS"

          mv "$TMP_CHECKSUMS" "$CHECKSUMS_PATH"

          {
            echo "# Encrypted MySQL backup"
            echo
            echo "* Backup name: \`$BACKUP_NAME\`"
            echo "* Created at: \`$STAMP\` UTC"
            echo "* Mode: \`$MODE\`"
            echo "* Encrypted size: \`$TOTAL_SIZE_BYTES\` bytes"
            echo "* SHA256 of assembled encrypted backup: \`$ORIGINAL_SHA256\`"
            echo "* Manifest: \`$MANIFEST_NAME\`"
            echo "* Checksums: \`$CHECKSUMS_NAME\`"
            echo

            if [ "$MODE" = "single-file" ]; then
              echo "## Restore assembly"
              echo
              echo "This backup is stored as a single encrypted file:"
              echo
              echo "\`\`\`sh"
              echo "age -d -i backup-key.txt < $BACKUP_FILE > backup.processed"
              echo "\`\`\`"
            else
              echo "## Restore assembly"
              echo
              echo "This backup is split into $PART_COUNT encrypted parts."
              echo
              echo "Reassemble the encrypted backup first:"
              echo
              echo "\`\`\`sh"
              echo "cat ${BACKUP_FILE}.part-* > $BACKUP_FILE"
              echo "\`\`\`"
              echo
              echo "Then decrypt it:"
              echo
              echo "\`\`\`sh"
              echo "age -d -i backup-key.txt < $BACKUP_FILE > backup.processed"
              echo "\`\`\`"
            fi

            echo
            echo "The decrypted \`backup.processed\` file is the output of the server-side processing command configured during setup."
          } > "$NOTES_PATH"

          FINAL_ASSET_COUNT="$(find "$ASSET_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"

          if [ "$FINAL_ASSET_COUNT" -gt "$MAX_RELEASE_ASSETS" ]; then
            echo "::error::Prepared $FINAL_ASSET_COUNT assets, but the configured single-release limit is $MAX_RELEASE_ASSETS"
            exit 1
          fi

          echo "Prepared assets:"
          find "$ASSET_DIR" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort

          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
          echo "title=$RELEASE_TITLE" >> "$GITHUB_OUTPUT"
          echo "mode=$MODE" >> "$GITHUB_OUTPUT"
          echo "part_count=$PART_COUNT" >> "$GITHUB_OUTPUT"
          echo "asset_count=$FINAL_ASSET_COUNT" >> "$GITHUB_OUTPUT"
          echo "size_bytes=$TOTAL_SIZE_BYTES" >> "$GITHUB_OUTPUT"
          echo "sha256=$ORIGINAL_SHA256" >> "$GITHUB_OUTPUT"
          echo "asset_dir=$ASSET_DIR" >> "$GITHUB_OUTPUT"
          echo "notes_path=$NOTES_PATH" >> "$GITHUB_OUTPUT"

      - name: Create GitHub Release
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ steps.backup.outputs.tag }}
          TITLE: ${{ steps.backup.outputs.title }}
          ASSET_DIR: ${{ steps.backup.outputs.asset_dir }}
          NOTES_PATH: ${{ steps.backup.outputs.notes_path }}
        run: |
          set -Eeuo pipefail

          RELEASE_CREATED=0
          RELEASE_PUBLISHED=0

          cleanup_incomplete_release() {
            status="$?"

            if [ "$status" -ne 0 ] && [ "$RELEASE_CREATED" -eq 1 ] && [ "$RELEASE_PUBLISHED" -eq 0 ]; then
              echo "::warning::Deleting incomplete draft release $TAG"
              gh release delete "$TAG" \
                --yes \
                --cleanup-tag \
                --repo "$GITHUB_REPOSITORY" || true
            fi
          }

          trap cleanup_incomplete_release EXIT

          gh release create "$TAG" \
            --repo "$GITHUB_REPOSITORY" \
            --title "$TITLE" \
            --notes-file "$NOTES_PATH" \
            --target "$GITHUB_SHA" \
            --draft \
            --latest=false

          RELEASE_CREATED=1

          while IFS= read -r -d '' asset; do
            echo "Uploading $(basename "$asset")"
            gh release upload "$TAG" "$asset" \
              --repo "$GITHUB_REPOSITORY"
          done < <(find "$ASSET_DIR" -maxdepth 1 -type f -print0 | sort -z)

          gh release edit "$TAG" \
            --repo "$GITHUB_REPOSITORY" \
            --draft=false \
            --latest=false

          RELEASE_PUBLISHED=1

      - name: Write workflow summary
        shell: bash
        run: |
          set -euo pipefail

          {
            echo "## Encrypted MySQL backup"
            echo
            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Release tag | \`${{ steps.backup.outputs.tag }}\` |"
            echo "| Mode | \`${{ steps.backup.outputs.mode }}\` |"
            echo "| Part count | \`${{ steps.backup.outputs.part_count }}\` |"
            echo "| Uploaded assets | \`${{ steps.backup.outputs.asset_count }}\` |"
            echo "| Encrypted size | \`${{ steps.backup.outputs.size_bytes }}\` bytes |"
            echo "| SHA256 | \`${{ steps.backup.outputs.sha256 }}\` |"
          } >> "$GITHUB_STEP_SUMMARY"
```

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

## Configuration reference

| Name                 | Required | Default                                  | Used by                    | Store as GitHub secret | Description                                                                                            |
| -------------------- | -------: | ---------------------------------------- | -------------------------- | ---------------------: | ------------------------------------------------------------------------------------------------------ |
| `SSH_HOST`           |      Yes | —                                        | GitHub Actions             |                    Yes | Hostname or IP address of the backup server.                                                           |
| `SSH_PORT`           |       No | `22`                                     | GitHub Actions             |               Optional | SSH port of the backup server. Can be a secret or a repository variable.                               |
| `SSH_PRIVATE_KEY`    |      Yes | —                                        | GitHub Actions             |                    Yes | Private SSH key used by GitHub Actions to connect to the backup server.                                |
| `SSH_PUBLIC_KEY`     |      Yes | —                                        | `setup.sh`                 |                     No | Public SSH key installed for the restricted backup user.                                               |
| `AGE_PUBLIC_KEY`     |      Yes | —                                        | `setup.sh`                 |                     No | Public `age` key used to encrypt backups.                                                              |
| `DB_NAME`            |      Yes | —                                        | `setup.sh`                 |                     No | MySQL database name to back up.                                                                        |
| `BACKUP_USER`        |       No | `backup`                                 | `setup.sh`, GitHub Actions |                     No | Linux user used for SSH backup access. Must match in setup and workflow.                               |
| `BACKUP_HOME`        |       No | `/home/$BACKUP_USER`                     | `setup.sh`                 |                     No | Home directory of the Linux backup user.                                                               |
| `BACKUP_COMMAND`     |       No | `/usr/local/sbin/github-mysql-backup.sh` | `setup.sh`                 |                     No | Path where the forced backup command is installed.                                                     |
| `MYSQL_USER`         |       No | `backup`                                 | `setup.sh`                 |                     No | MySQL user used for backup operations.                                                                 |
| `MYSQL_PASSWORD`     |      Yes | —                                        | `setup.sh`, GitHub Actions |                    Yes | Password for the MySQL backup user.                                                                    |
| `MYSQL_HOST_PATTERN` |       No | `localhost`                              | `setup.sh`                 |                     No | MySQL host pattern for the backup user.                                                                |
| `MYSQLDUMP_CMD`      |       No | `mysqldump`                              | `setup.sh`                 |                     No | Command used to create the database dump. Runs before encryption and must be trusted.                  |
| `MYSQL_CHARSET`      |       No | `utf8mb4`                                | `setup.sh`                 |                     No | MySQL client character set used during backup execution.                                               |
| `MYSQL_ADMIN_CMD`    |       No | `mysql`                                  | `setup.sh`                 |                     No | Command used to configure MySQL users and grants.                                                      |
| `PROCESS_COMMAND`    |       No | `zstd -19`                               | `setup.sh`                 |                     No | Command used to process the dump stream before encryption. Runs before encryption and must be trusted. |
| `BACKUP_NAME`        |       No | `mysql`                                  | GitHub Actions             |                     No | Human-readable backup name used in release titles and metadata.                                        |
| `RELEASE_PREFIX`     |       No | `mysql-backup`                           | GitHub Actions             |                     No | Prefix used for GitHub Release tags.                                                                   |
| `ASSET_PREFIX`       |       No | `mysql-backup`                           | GitHub Actions             |                     No | Prefix used for uploaded release asset names.                                                          |
| `SPLIT_SIZE_BYTES`   |       No | `2000000000`                             | GitHub Actions             |                     No | Split size for release assets. Must be lower than 2 GiB.                                               |
