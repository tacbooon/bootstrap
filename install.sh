#!/usr/bin/env bash

set -euo pipefail

print_error() {
  echo "[Error]: $*" >&2
}

print_error_and_exit() {
  print_error "$@"
  exit 1
}

# このスクリプトは root 権限で実行すべきではありません。
if [ "$(id -u)" -eq 0 ]; then
  print_error_and_exit "Do not run this script with sudo or as the root user."
fi

# OS を検出します。失敗した場合はスクリプトを終了します。
case "$(uname -s)" in
  Darwin)
    OS_TYPE="macos"
    ;;
  Linux)
    OS_TYPE="linux"
    if [ -f /etc/os-release ]; then
      OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
      if [ "$OS_ID" = "nixos" ]; then
        OS_TYPE="nixos"
      fi
    fi
    ;;
  *)
    print_error_and_exit "Unsupported OS detected: $(uname -s)"
    ;;
esac
echo "Starting installation on $OS_TYPE..."

# ホストを入力します。デフォルトでは現在のホスト名をそのまま使用します。
DEFAULT_HOSTNAME="$(hostname -s)"
read -r -p "Please enter hostname (default: $DEFAULT_HOSTNAME): " NEW_HOSTNAME < /dev/tty
NEW_HOSTNAME="${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}"
if [ "$NEW_HOSTNAME" != "$DEFAULT_HOSTNAME" ]; then
  echo "Setting hostname..."
  case "$OS_TYPE" in
    macos)
      sudo scutil --set ComputerName "$NEW_HOSTNAME"
      sudo scutil --set HostName "$NEW_HOSTNAME"
      sudo scutil --set LocalHostName "$NEW_HOSTNAME"
      ;;
    nixos|linux)
      sudo hostname "$NEW_HOSTNAME"
      ;;
  esac
fi

# Nix がインストールされているかを確認し、インストールされていない場合はインストールします。
if command -v nix &> /dev/null; then
  echo "nix is already installed."
else
  echo "Installing nix..."
  curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --enable-flakes
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# SSH 鍵が存在するかを確認し、存在しない場合は生成します。
PRIVATE_KEY_PATH="$HOME/.ssh/id_ed25519"
PUBLIC_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
if [ -f "$PUBLIC_KEY_PATH" ]; then
  echo "SSH key already exists at $PUBLIC_KEY_PATH"
else
  echo "Generating SSH key..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  nix-shell -p openssh --run "ssh-keygen -t ed25519 -N '' -f '$PRIVATE_KEY_PATH' -C '$NEW_HOSTNAME'"
fi

# GitHub に SSH 公開鍵を登録するように促します。
echo "Please add the following SSH public key to your GitHub account"
cat "$PUBLIC_KEY_PATH"
read -r -p "Press Enter to continue installation" < /dev/tty

# dotfiles をリポジトリから取得してホームディレクトリ以下に展開します。
DOTFILES_DIR="$HOME/src/tacbooon/dotfiles"
DOTFILES_URL="git@github.com:tacbooon/dotfiles.git"
if [ -d "$DOTFILES_DIR/.git" ]; then
  echo "dotfiles repository already exists at $DOTFILES_DIR"
else
  mkdir -p "$DOTFILES_DIR"
  nix-shell -p git openssh --run "\
    env GIT_SSH_COMMAND='ssh -i $PRIVATE_KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
    git clone '$DOTFILES_URL' '$DOTFILES_DIR'"
fi

# dotfiles を使ってシステム設定を再構築します。
echo "Rebuilding system configuration using flake..."
FLAKE_PATH="$DOTFILES_DIR#$NEW_HOSTNAME"
case "$OS_TYPE" in
  macos)
    for rc in /etc/bashrc /etc/zshrc; do
      if [ -f "$rc" ]; then
        if [ ! -f "${rc}.before-nix-darwin" ]; then
          sudo mv "$rc" "${rc}.before-nix-darwin"
        fi
      fi
    done
    if [ -f /etc/bashrc ] && [ ! -f /etc/bashrc.before-nix-darwin ]; then
      sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
    fi
    if [ -f /etc/zshrc ] && [ ! -f /etc/zshrc.before-nix-darwin ]; then
      sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
    fi
    sudo nix run nix-darwin/master#darwin-rebuild -- switch --flake "$FLAKE_PATH"
    ;;
  nixos)
    sudo nixos-rebuild switch --flake "$FLAKE_PATH"
    ;;
  linux)
    sudo nix run nixpkgs#home-manager -- switch --flake "$FLAKE_PATH"
    ;;
esac

# インストールが完了しました。PATH を更新するために新しいシェルを起動します。
echo "Installation completed successfully!"
exec "$SHELL" -l
