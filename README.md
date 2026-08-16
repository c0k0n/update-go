# update-go

A tiny, careful helper that updates the [Go](https://go.dev) toolchain on your
machine with a single command.

Go ships new releases often, but it has no built-in auto-updater. Updating
usually means: open the downloads page, find the right tarball for your OS and
arch, download it, verify the checksum, delete the old `/usr/local/go`, extract
the new one, and make sure your `PATH` is right. It's not hard — it's just
tedious, and I kept doing it by hand. So I wrote this little script to do it for
me, and I'm sharing it in case it helps you too.

On Linux and macOS it downloads the official archive straight from `go.dev`,
verifies the published SHA-256 checksum, and replaces `/usr/local/go` in place.

It also works as a first-time installer: if you don't have Go yet, running it will
fetch and install the latest version for you — no separate setup step. (That's also
why it needs `sudo`: it writes to `/usr/local/go`.)

---

## Disclaimer

**This is a personal tool. It is not affiliated with, maintained by, or endorsed
by the Go project or the Go authors in any way.** It's just a small script I
wrote and use myself. It works for me, but use it at your own risk — and if you
spot something wrong, please let me know (see [Contributing](#contributing)).

---

## Features

- Detects your OS (`linux` / `darwin`) and architecture (`amd64` / `arm64`)
  automatically.
- Fetches the latest Go release info directly from `https://go.dev/dl/?mode=json`.
- Verifies the official SHA-256 checksum of the downloaded tarball **before**
  touching your existing install — and aborts if it doesn't match.
- Installs to `/usr/local/go` (the same location the official installers use).
- Doubles as a first-time installer: if Go isn't installed yet, it just installs the
  latest version for you — no separate "download the installer first" step.
- Detects your shell from `$SHELL` and adds the right `PATH` lines:
  - **bash** → `~/.bashrc` (Linux) or `~/.bash_profile` (macOS)
  - **zsh** → `~/.zshrc`
  - **fish** → `~/.config/fish/config.fish` (using `set -gx PATH ...`)
- Also adds `$GOPATH/bin` to `PATH` so your installed Go tools are reachable.
- Won't reinstall if you're already on the latest version (unless you ask it
  to with `--force`).
- Supports `-f/--force` to reinstall the same version, and `-h/--help`.

---

## Requirements

- A `bash` shell.
- [`curl`](https://curl.se) — used to fetch the release info and tarball.
- [`jq`](https://jqlang.github.io/jq/) — used to parse the release JSON.
- `sudo` — needed to write to `/usr/local/go`.

If `curl` or `jq` are missing, the script will tell you and exit. On macOS you
may need to install `jq` first:

```sh
brew install jq
```

(On Debian/Ubuntu: `sudo apt install jq`.)

---

## Installation

The idea is simply to drop the script somewhere on your `PATH` and make it
executable, then run it whenever you want to update Go.

### Linux

```sh
curl -fsSL https://raw.githubusercontent.com/c0k0n/update-go/main/update-go -o ~/.local/bin/update-go && chmod +x ~/.local/bin/update-go
```

Make sure `~/.local/bin` is on your `PATH` (most distros include it by
default). After that, `update-go` should resolve to
`/home/<you>/.local/bin/update-go`.

### macOS

```sh
sudo curl -fsSL https://raw.githubusercontent.com/c0k0n/update-go/main/update-go -o /usr/local/bin/update-go && sudo chmod +x /usr/local/bin/update-go
```

(`/usr/local/bin` is on the default `PATH` on macOS. You can also use `~/bin`
if you prefer.)

Note: the official Go macOS `.pkg` installer puts Go in `/usr/local/go` and
adds `/etc/paths.d/go` to your `PATH`. This script uses that same
`/usr/local/go` location via the official tarball, so it stays compatible with
how Go is normally installed on a Mac.

---

## Usage

Just run it:

```sh
update-go
```

Options:

```sh
update-go --force   # reinstall even if you're already on the latest version
update-go --help    # show the help text
```

**First run vs. upgrades:** if `go` isn't installed at all, the script downloads
the latest version, verifies it, and installs it fresh to `/usr/local/go` — so it
works as a one-command installer the very first time. If `go` is already installed
and on the latest version, it'll tell you you're up to date and exit (unless you
pass `--force`). Otherwise it downloads the newer version, verifies it, removes the
old `/usr/local/go`, and extracts the new one.

**After it finishes,** you may need to open a new terminal (or `source` your
profile — the script prints the exact command) before the updated `go` is on
your `PATH` in existing shells.

---

## Supported platforms

| OS      | Architectures              | Shells                |
| ------- | -------------------------- | --------------------- |
| Linux   | `amd64`, `arm64`           | bash, zsh, fish       |
| macOS   | Intel `amd64`, Apple Silicon `arm64` | bash, zsh, fish |

Other operating systems (notably Windows) are **not** supported — the script
detecting something else will exit with a friendly message.

---

## How it works

It's deliberately simple and a little paranoid:

1. It fetches the official release list from `https://go.dev/dl/?mode=json`.
2. It reads the latest version and the published SHA-256 checksum for your
   OS/arch.
3. It downloads the official tarball and **verifies the checksum against the
   published value** before doing anything else. If they don't match, it stops
   and leaves your system untouched.
4. Only then does it remove `/usr/local/go` and extract the new archive.
5. Finally it makes sure your shell profile points at the new install.

So in the worst case (a bad download), nothing on your machine is modified.

---

## Uninstalling

There's nothing to "uninstall" as such — it's one script:

```sh
rm ~/.local/bin/update-go        # Linux
# or
sudo rm /usr/local/bin/update-go  # macOS
```

If you also want to remove Go itself:

```sh
sudo rm -rf /usr/local/go
```

And if you'd like to clean up, the script added a couple of lines to your shell
profile (e.g. `~/.bashrc`, `~/.zshrc`, or `~/.config/fish/config.fish`) for the
`/usr/local/go/bin` and `$GOPATH/bin` `PATH` entries — feel free to remove those
too.

---

## Contributing

This is a small personal project, but I'm happy to hear from you. If something
doesn't work on your setup, or you have a modest improvement in mind, please
open an issue or a pull request. Keep it kind and keep it small. 🙂

---

## License

Released under the [MIT License](LICENSE).
