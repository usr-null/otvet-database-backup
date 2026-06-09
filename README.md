# mysql-crypto-backup

This repository provides a simple way to automate MySQL database backups using GitHub Actions. Backups are compressed, encrypted with age before leaving the server, and can be stored in a public GitHub repository without exposing database contents.

By combining end-to-end encryption with the generous free tier available to public GitHub repositories, it enables low-cost, automated, and privacy-preserving off-site backups without requiring dedicated backup infrastructure.

## Installing
Install required packages on the MySQL server:

To get started, fork this repository to your GitHub account. You'll use your fork to configure the required secrets and define the server that will be backed up.

```sh
apt update
apt install -y mysql-client zstd age openssh-server
````

Generate an age key on your local machine:

```sh
age-keygen -o backup-key.txt
```

Copy the public key from the output, it starts with:

```text
age1...
```

Run setup on the server as root:

```sh
curl -fsSL https://raw.githubusercontent.com/your-name/your-fork/refs/heads/main/setup.sh | \
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-mysql-password' \
sh
```

If MySQL admin access requires `sudo mysql`, use:

```sh
curl -fsSL https://raw.githubusercontent.com/usr-null/mysql-crypto-backup/refs/heads/main/setup.sh | \
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
AGE_PUBLIC_KEY='age1...' \
DB_NAME='my_database' \
MYSQL_PASSWORD='strong-backup-mysql-password' \
MYSQL_ADMIN_CMD='sudo mysql' \
sh
```
