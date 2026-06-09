# mysql-crypto-backup

Automated encrypted MySQL backups using GitHub Actions.

This repository provides a simple way to create off-site MySQL database backups using GitHub Actions. Backups are compressed and encrypted with age on the server before being transferred, so they can be safely stored in a public GitHub repository without exposing database contents.

By combining end-to-end encryption with GitHub's free infrastructure for public repositories, this project provides a low-cost, automated, and privacy-preserving backup setup without requiring dedicated backup servers or paid storage.

To get started, fork this repository to your GitHub account. Your fork will be used to configure repository secrets and define the server that should be backed up.

## Installing

Install the required packages on the MySQL server:

```sh
apt update
apt install -y mysql-client zstd openssh-server curl

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

Copy the public key printed by `age-keygen`. It starts with:

```text
age1...
```

Run the setup script on the MySQL server as root:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh | \
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-mysql-password' \
sh
```

The setup script will create a restricted `backup` system user, install a forced SSH command, create a limited MySQL user, and allow that user to dump only the selected database.

If MySQL administrative access requires a custom command, specify it with `MYSQL_ADMIN_CMD`:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh | \
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-mysql-password' \
MYSQL_ADMIN_CMD='sudo mysql' \
sh
```
