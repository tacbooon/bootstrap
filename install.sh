#!/usr/bin/env bash

set -euo pipefail

# Nix のインストール方法によっては Flake が無効化されているため明示的に有効化するオプションです。
EXTRA_NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

print_error() {
  echo "[Error]: $*" >&2
}

print_error_and_exit() {
  print_error "$@"
  exit 1
}

# Nix のプロファイルを読み込みます。既に nix が PATH にあれば何もしません。
load_nix_profile() {
  if command -v nix >/dev/null 2>&1; then
    return 0
  fi
  local init_script
  local xdg_profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profile"
  for init_script in \
    "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" \
    "/nix/var/nix/profiles/default/etc/profile.d/nix.sh" \
    "$HOME/.nix-profile/etc/profile.d/nix.sh" \
    "$xdg_profile/etc/profile.d/nix.sh" \
    "/nix/profile/etc/profile.d/nix.sh"; do
    if [ -f "$init_script" ]; then
      set +eu
      . "$init_script" || true
      set -eu
    fi
    if command -v nix >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# ssh-keygen が存在すれば直接実行し、存在しなければ nix shell 経由で実行します。
run_ssh_keygen() {
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen "$@"
  else
    nix "${EXTRA_NIX_FLAGS[@]}" shell nixpkgs#openssh --command ssh-keygen "$@"
  fi
}

# git が存在すれば直接実行し、存在しなければ nix shell 経由で実行します。
run_git() {
  if command -v git >/dev/null 2>&1; then
    git "$@"
  else
    nix "${EXTRA_NIX_FLAGS[@]}" shell nixpkgs#git nixpkgs#openssh --command git "$@"
  fi
}

# このスクリプトは root 権限で実行すべきではありません。
if [ "$(id -u)" -eq 0 ]; then
  print_error_and_exit "Do not run this script with sudo or as the root user."
fi

# 一時作業用ディレクトリ。EXIT 時に確実に削除される。
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:-}"' EXIT

# OS を検出します。失敗した場合はスクリプトを終了します。
case "$(uname -s)" in
  Darwin)
    OS_TYPE="macos"
    ;;
  Linux)
    OS_TYPE="linux"
    if [ -f /etc/os-release ]; then
      OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)
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
DEFAULT_HOSTNAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo localhost)"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME%%.*}"
read -r -p "Please enter hostname (default: $DEFAULT_HOSTNAME): " NEW_HOSTNAME < /dev/tty || true
NEW_HOSTNAME="${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}"
NEW_HOSTNAME="${NEW_HOSTNAME#"${NEW_HOSTNAME%%[![:space:]]*}"}"
NEW_HOSTNAME="${NEW_HOSTNAME%"${NEW_HOSTNAME##*[![:space:]]}"}"
NEW_HOSTNAME="${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}"
if [[ ! "$NEW_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  print_error_and_exit "invalid hostname: '$NEW_HOSTNAME' (use lowercase alphanumeric characters and hyphens)"
fi

# Mac は nix-darwin でホスト名を管理できないため、ここでホスト名を設定します。
# Linux は rebuild 時に設定されるためここで設定する必要はありません。
if [ "$NEW_HOSTNAME" != "$DEFAULT_HOSTNAME" ] && [ "$OS_TYPE" = "macos" ]; then
  echo "Setting hostname..."
  sudo scutil --set ComputerName "$NEW_HOSTNAME"
  sudo scutil --set HostName "$NEW_HOSTNAME"
  sudo scutil --set LocalHostName "$NEW_HOSTNAME"
fi

# Nix がインストールされているかを確認し、インストールされていない場合はインストールします。
if command -v nix >/dev/null 2>&1; then
  echo "nix is already installed."
else
  # インストール済の Nix に PATH が通っていないだけかもしれないのでプロファイルを読み込みます。
  load_nix_profile
  if command -v nix >/dev/null 2>&1; then
    echo "nix is already installed."
  else
    echo "Installing nix..."
    curl --proto '=https' --tlsv1.2 -sSfL https://artifacts.nixos.org/nix-installer -o "$WORK_DIR/nix-installer.sh"
    sh "$WORK_DIR/nix-installer.sh" install --enable-flakes
    load_nix_profile
    command -v nix >/dev/null 2>&1 || print_error_and_exit "nix not found in PATH after install"
  fi
fi

# SSH 鍵が存在するかを確認し、存在しない場合は生成します。
PRIVATE_KEY_PATH="$HOME/.ssh/id_ed25519"
PUBLIC_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ -f "$PRIVATE_KEY_PATH" ] && [ -f "$PUBLIC_KEY_PATH" ]; then
  echo "SSH key already exists at $PUBLIC_KEY_PATH"
elif [ -f "$PRIVATE_KEY_PATH" ]; then
  echo "Private key exists but public key is missing, regenerating public key..."
  run_ssh_keygen -y -f "$PRIVATE_KEY_PATH" > "$PUBLIC_KEY_PATH"
elif [ -f "$PUBLIC_KEY_PATH" ]; then
  print_error_and_exit "public key exists but private key is missing: $PRIVATE_KEY_PATH"
else
  echo "Generating SSH key..."
  run_ssh_keygen -t ed25519 -N '' -f "$PRIVATE_KEY_PATH" -C "$NEW_HOSTNAME"
fi
chmod 600 "$PRIVATE_KEY_PATH"
chmod 644 "$PUBLIC_KEY_PATH"

# GitHub に SSH 公開鍵を登録するように促します。
echo "Please add the following SSH public key to your GitHub account"
cat "$PUBLIC_KEY_PATH"
read -r -p "Press Enter to continue installation" < /dev/tty || true

# dotfiles をリポジトリから取得してホームディレクトリ以下に展開します。
DOTFILES_DIR="$HOME/src/tacbooon/dotfiles"
DOTFILES_URL="git@github.com:tacbooon/dotfiles.git"
export GIT_SSH_COMMAND="ssh -i \"$PRIVATE_KEY_PATH\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
mkdir -p "$(dirname "$DOTFILES_DIR")"
if [ -d "$DOTFILES_DIR/.git" ]; then
  echo "dotfiles repository already exists at $DOTFILES_DIR, updating..."
  run_git -C "$DOTFILES_DIR" pull --ff-only || print_error_and_exit "Failed to pull tacbooon/dotfiles."
else
  run_git clone "$DOTFILES_URL" "$DOTFILES_DIR" || print_error_and_exit "Failed to clone tacbooon/dotfiles."
fi

# dotfiles を使ってシステム設定を再構築します。
echo "Rebuilding system configuration using flake..."
case "$OS_TYPE" in
  macos)
    for rc in /etc/bashrc /etc/zshenv /etc/zshrc; do
      if [ -f "$rc" ]; then
        if [ ! -f "${rc}.before-nix-darwin" ]; then
          sudo mv "$rc" "${rc}.before-nix-darwin"
        fi
      fi
    done
    # dotfiles の flake.lock に従う nix-darwin を使うために一度ビルドし、その成果物を使います。
    nix "${EXTRA_NIX_FLAGS[@]}" build "$DOTFILES_DIR#darwinConfigurations.$NEW_HOSTNAME.system" --out-link "$WORK_DIR/system" --print-build-logs
    sudo "$WORK_DIR/system/sw/bin/darwin-rebuild" switch --flake "$DOTFILES_DIR#$NEW_HOSTNAME" "${EXTRA_NIX_FLAGS[@]}"
    ;;
  nixos)
    sudo nixos-rebuild switch --flake "$DOTFILES_DIR#$NEW_HOSTNAME" "${EXTRA_NIX_FLAGS[@]}"
    ;;
  linux)
    # dotfiles の flake.lock に従う home manager を使うために一度ビルドし、その成果物を使います。
    nix "${EXTRA_NIX_FLAGS[@]}" build "$DOTFILES_DIR#homeConfigurations.$NEW_HOSTNAME.activationPackage" --out-link "$WORK_DIR/home" --print-build-logs
    "$WORK_DIR/home/activate"
    ;;
esac

echo "Installation completed successfully!"
echo "Please log out and log back in (or restart your terminal) to use the new environment."
