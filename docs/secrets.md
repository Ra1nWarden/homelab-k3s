# Secrets

This repo uses SOPS with age recipients for encrypted secrets that are safe to
commit.

The public age recipient is committed in `.sops.yaml`. The matching private age
identity must stay outside git.

## Tools

Install these on machines that need to encrypt or decrypt repo secrets:

```sh
brew install sops age
```

For Linux, use your distro packages or the upstream release binaries.

## Private Key Location

By default, SOPS looks for age identities in:

```text
macOS:  ~/Library/Application Support/sops/age/keys.txt
Linux:  ~/.config/sops/age/keys.txt
```

Print the public recipient for a local identity:

```sh
age-keygen -y "$HOME/Library/Application Support/sops/age/keys.txt"
```

For Linux:

```sh
age-keygen -y "${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
```

Never commit the private identity file or any value beginning with:

```text
AGE-SECRET-KEY-
```

## Store the Private Key in 1Password

Create a 1Password item such as:

```text
Vault: Private
Item: homelab sops age key
Field: private key
```

Store the contents of your local SOPS age key file in that concealed field.

If the 1Password CLI is installed, you can use a secret reference instead of a
local `keys.txt` file:

```sh
export SOPS_AGE_KEY_CMD='op read "op://Private/homelab sops age key/private key"'
```

The `op` CLI must be installed and signed in for that to work.

## Create an Encrypted Env File

Create or edit the local plaintext file. Plaintext env files are ignored by git:

```sh
cp proxmox/openclaw/openclaw-lxc.env.example proxmox/openclaw/openclaw-lxc.env
vi proxmox/openclaw/openclaw-lxc.env
```

Encrypt it:

```sh
sops encrypt --input-type dotenv --output-type dotenv \
  --filename-override proxmox/openclaw/openclaw-lxc.env.sops \
  proxmox/openclaw/openclaw-lxc.env \
  > proxmox/openclaw/openclaw-lxc.env.sops
```

Commit only the `.sops` file.

## Edit Encrypted Files

For normal day-to-day edits, edit through SOPS directly:

```sh
sops proxmox/openclaw/openclaw-lxc.env.sops
```

SOPS opens the decrypted content in your editor and re-encrypts it when you
save and exit.

Set your editor if needed:

```sh
export EDITOR=vim
export EDITOR=nano
export EDITOR="code --wait"
```

## Decrypt for Local Use

Decrypt to an ignored plaintext file:

```sh
sops decrypt --input-type dotenv --output-type dotenv \
  proxmox/openclaw/openclaw-lxc.env.sops \
  > proxmox/openclaw/openclaw-lxc.env
chmod 600 proxmox/openclaw/openclaw-lxc.env
```

Because `>` truncates the output file, rerunning the same command overwrites an
existing plaintext env file.

If you only need to inspect values, print plaintext to stdout instead:

```sh
sops decrypt --input-type dotenv --output-type dotenv \
  proxmox/openclaw/openclaw-lxc.env.sops
```

## Use With Proxmox

The Proxmox node does not need SOPS or age. Decrypt on your Mac, then copy or
stream plaintext to Proxmox.

Write the env file on Proxmox:

```sh
sops decrypt proxmox/openclaw/openclaw-lxc.env.sops \
  | ssh root@<proxmox-ip> 'cat > /root/homelab/proxmox/openclaw/openclaw-lxc.env && chmod 600 /root/homelab/proxmox/openclaw/openclaw-lxc.env'
```

Run the script on Proxmox:

```sh
ssh root@<proxmox-ip> 'cd /root/homelab/proxmox/openclaw && ./create-lxc.sh ./openclaw-lxc.env'
```

## Update Recipients

After changing `.sops.yaml`, sync encrypted files with:

```sh
sops updatekeys proxmox/openclaw/openclaw-lxc.env.sops
```

## Rotate Data Keys

Rotate the SOPS data key:

```sh
sops rotate -i proxmox/openclaw/openclaw-lxc.env.sops
```

## Recovery Warning

If you lose the age private identity and do not have another recipient on the
file, you lose access to the encrypted secrets. Back up the private identity in
1Password or another secure recovery location.
