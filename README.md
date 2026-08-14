# Bootstrap

PC やサーバーをセットアップするために使用する個人用のブートストラップスクリプトです。

## 動作環境

tacbooon/dotfiles を参照してください。

## 使い方

`root` ユーザや `sudo` は使用せず一般ユーザで `install.sh` を実行してください。これには以下のような方法があります。

### curl

通常、MacOS や NixOS では `curl` がプリインストールされています。

```shellsession
$ /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tacbooon/bootstrap/main/install.sh)"
```

### nix

既に `nix` を利用できる環境では `nix-shell` 経由で `curl` を実行できます。

```shellsession
$ nix-shell -p curl --run 'bash <(curl -fsSL https://raw.githubusercontent.com/tacbooon/bootstrap/main/install.sh)'
```

### git

このリポジトリをクローンしてから `install.sh` を実行しても構いません。

```shellsession
$ mkdir -p "$HOME/src/tacbooon"
$ git clone git@github.com:tacbooon/bootstrap.git "$HOME/src/tacbooon/bootstrap"
$ bash "$HOME/src/tacbooon/bootstrap/install.sh"
```
