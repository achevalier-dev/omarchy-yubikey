# omarchy-yubikey

YubiKey for [Omarchy](https://omarchy.org): menu entries for the things you
actually reach for — a 2FA code on the clipboard, the applications on the key,
and the two repairs that fix a key that has stopped answering.

## What you get

`Super+Space` then type `yubikey` (or `2fa`), or jump straight there:

```bash
omarchy menu summon yubikey
```

- **2FA Code** — pick an OATH account, get the code on your clipboard, and it
  clears itself 30 seconds later. Prompts you to touch the key when the account
  requires it, and falls back to a terminal if the OATH application is password
  protected.
- **Key Info** — serial, firmware, and which applications are enabled
- **OATH Accounts** — what is stored on the key
- **Authenticator** — launches Yubico Authenticator, or focuses it if it is
  already open
- **Applications** — PIV, FIDO2, Passkeys, OpenPGP, and OTP slots
- **Login With Key** — hands off to Omarchy's own FIDO2 login setup
- **Troubleshoot** — enable the smart card daemon, or restart the GPG agent when
  the card stops answering after a suspend or a re-plug

Anything that needs a PIN, a password, or a long readout opens a floating
terminal. Everything else reports back as a notification.

## Install

```bash
git clone https://github.com/achevalier-dev/omarchy-yubikey.git
cd omarchy-yubikey && ./install.sh
```

`install.sh` symlinks `bin/yubikey-menu` into `~/.local/bin` and merges the menu
rows into `~/.config/omarchy/extensions/omarchy-menu.jsonc`, backing the file up
first. It is safe to re-run — the block is replaced, never duplicated.

## Requirements

- Omarchy 4.x
- `yubikey-manager` (`ykman`)
- `pcsclite` **and a running pcscd** — OATH, PIV and OpenPGP speak CCID and need
  it; FIDO and OTP go over raw HID and do not:

  ```bash
  sudo systemctl enable --now pcscd.socket
  ```

  The menu's *Troubleshoot → Enable Smart Card Daemon* row does this for you,
  and hides itself once pcscd is running.

- Optional: `yubico-authenticator` for the GUI row

### GnuPG and pcscd

With pcscd running, GnuPG's `scdaemon` may fail to claim the reader —
`gpg --card-status` reports *"selecting card failed: No such device"*. Tell
scdaemon to go through PC/SC instead of driving CCID itself:

```bash
echo disable-ccid >> ~/.gnupg/scdaemon.conf
gpgconf --kill scdaemon gpg-agent
```

## How it works

`bin/yubikey-menu` is a plain bash script — no daemon, no background process.
It draws its pickers with `omarchy-menu-select`, reports through
`omarchy-notification-send`, and opens `omarchy-launch-floating-terminal-with-presentation`
for anything interactive. Usable on its own:

```bash
yubikey-menu code        # pick an account, copy the code
yubikey-menu info        # ykman info in a floating terminal
yubikey-menu reset-gpg   # restart scdaemon and re-read the card
```

## Uninstall

```bash
rm ~/.local/bin/yubikey-menu
```

Then delete the `// >>> omarchy-yubikey` … `// <<< omarchy-yubikey` block from
`~/.config/omarchy/extensions/omarchy-menu.jsonc`.

## License

MIT
