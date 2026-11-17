# sftpc - Lightweight SFTP-Only Container

While there are several ways to run an SFTP server under a non-privileged cluster account (like running `sshd` directly, using `rclone`, or building a custom Apptainer/Docker image), `sftpc` uses a small Bash script (`sftpc.sh`) to manually construct a minimal, SFTP-only container.

## Why Containerize?

* **Password Authentication:** Host `sshd` daemons on clusters typically enforce SSH keys and disable password logins. Running an isolated `sshd` instance inside a container allows password-based authentication without root access or altering system configs.
* **Zero Image Maintenance:** All required binaries are bound directly from the host, meaning security updates are handled automatically by your host's package manager.

## Prerequisites

* Unprivileged `user namespaces` enabled on the host.
* Configured `subuid` and `subgid` ranges for your user account.
* An open, unfirewalled port above `1024`.

## Usage

```bash
chmod +x sftpc.sh
./sftpc.sh DIRECTORY [PORT [LISTEN_ADDRESS]]
```
