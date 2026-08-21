# update-go

A tiny, careful helper that updates the [Go](https://go.dev) toolchain with a
single command.

Go ships new releases often, but it has no built-in auto-updater. Doing it by
hand means finding the right tarball, verifying it, deleting the old install,
extracting the new one, and hoping your `PATH` is still right. It's not hard —
it's just tedious, and I kept doing it by hand. So I wrote this little script
to do it for me, and I'm sharing it in case it helps you too.

> **Heads-up:** this is a personal tool. It is not affiliated with, maintained
> by, or endorsed by the Go project in any way. It works for me, but use it at
> your own risk — and if you spot something wrong, please let me know (see
> [Contributing](#contributing)).

## What it does

In the order it happens:

- Asks `go.dev` for the release you want — the latest by default, or any
  specific stable version (`update-go 1.25.4`). Nothing else is hardcoded.
- Checks what you have now. Already on it? It says so and stops
  (unless you pass `--force`). The check looks at `/usr/local/go`
  specifically, so another `go` elsewhere on your `PATH` (Homebrew, version
  managers, …) won't fool it. No Go at all? It simply installs —
  the first run doubles as the installer.
- Downloads the official tarball for your OS and architecture, sanity-checks
  that the archive looks like what Go actually ships, and verifies its
  published SHA-256 checksum **before** touching anything. A mismatch stops
  everything, leaving your system exactly as it was.
- Removes `/usr/local/go` and extracts the fresh archive — the same location,
  and the same remove-first approach, that the official installation docs
  recommend (untarring over an existing tree is known to break installs).
- Verifies the new install actually reports the expected version before
  calling it done.
- Adds `/usr/local/go/bin` and `$GOPATH/bin` to your `PATH`, based on your
  `$SHELL`:
  - **bash** → `~/.bashrc` (Linux) or `~/.bash_profile` (macOS)
  - **zsh** → `~/.zshrc`
  - **fish** → `$XDG_CONFIG_HOME/fish/config.fish` (defaulting to
    `~/.config/fish/config.fish`), using fish's own `fish_add_path`

  Lines your profile already has are skipped, so nothing gets duplicated —
  even if you added Go to your `PATH` by hand long ago.
- Retries flaky downloads a few times, and every failure exits with a
  plain-language message telling you what to try next.
- Won't fight itself: a lock file stops two copies from running at once.
- Can update itself with `--update`: it fetches the newest release, verifies
  it against the release's published `SHA256SUMS` (telling you if that file
  is unavailable), checks it over (shebang and syntax) before touching
  anything, and replaces the running copy — using `sudo` only if the install
  location needs it.
- Can preview with `--check`: shows what it would do — versions, tarball,
  profile changes — without changing anything.
- Can clean up after itself with `--uninstall`: removes `/usr/local/go` and
  the exact PATH lines it added (after asking you first). Your code and
  modules in `~/go` are never touched.

## Requirements

- A `bash` shell.
- [`curl`](https://curl.se) and [`jq`](https://jqlang.github.io/jq/) — if
  either is missing, the script tells you how to install it and exits.
- `sudo` — writing to `/usr/local/go` needs root.

On macOS you may need `jq` first:

```sh
brew install jq
```

(On Debian/Ubuntu: `sudo apt install jq`.)

## Installation

Drop the script somewhere on your `PATH` and make it executable.

Linux:

```sh
curl -fsSL https://github.com/c0k0n/update-go/releases/latest/download/update-go -o ~/.local/bin/update-go && chmod +x ~/.local/bin/update-go
```

Make sure `~/.local/bin` is on your `PATH` (most distros include it by
default).

macOS:

```sh
sudo curl -fsSL https://github.com/c0k0n/update-go/releases/latest/download/update-go -o /usr/local/bin/update-go && sudo chmod +x /usr/local/bin/update-go
```

(`/usr/local/bin` is on the default `PATH` on macOS. You can also use `~/bin`
if you prefer.)

## Usage

```sh
update-go              # update (or first-time install) to the latest Go
update-go 1.25.4       # install a specific version (stable releases only)
update-go --check      # preview what would happen, change nothing
update-go --force      # reinstall even if already on the requested version
update-go --update     # update update-go itself to the latest release
update-go --uninstall  # remove Go and the PATH lines update-go added
update-go --version    # show which release of update-go you're running
update-go --help       # show the help text
```

Released copies know their own version (the release automation stamps it in);
a copy run straight from the repository reports `dev`.

When it finishes, open a new terminal (or source your profile — the script
prints the exact command) so existing shells pick up the updated `go`.

## Supported platforms

| OS      | Architectures                       | Shells          |
| ------- | ----------------------------------- | --------------- |
| Linux   | `amd64`, `arm64`, `386`, `armv6l`   | bash, zsh, fish |
| macOS   | Intel `amd64`, Apple Silicon `arm64` | bash, zsh, fish |

Anything else — Windows included — prints a clear message and exits.

## Uninstalling

The easy way — it asks for confirmation, then removes `/usr/local/go`, any
leftover `/etc/paths.d/go`, and exactly the `PATH` lines it added. Your code
and modules in `~/go` are never touched:

```sh
update-go --uninstall
```

Or by hand — it's one script:

```sh
rm ~/.local/bin/update-go         # Linux
# or
sudo rm /usr/local/bin/update-go  # macOS

sudo rm -rf /usr/local/go         # if you want Go itself gone too
sudo rm -f /etc/paths.d/go        # if a macOS .pkg install left this behind
```

Then feel free to delete the two `PATH` lines from your shell profile
(`~/.bashrc`, `~/.zshrc`, or `~/.config/fish/config.fish`).

## Contributing

This is a small personal project, but I'm happy to hear from you — bugs,
ideas, and modest improvements are all welcome. Please see
[CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request.

## License

Released under the [MIT License](LICENSE).
