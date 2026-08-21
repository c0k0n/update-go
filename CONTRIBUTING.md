# Contributing

Thanks for wanting to help! This is a small personal project, so the rules are
small too.

## Found a bug?

Please [open an issue](https://github.com/c0k0n/update-go/issues) and include:

- Your OS, architecture, and shell (`uname -s -m`, `echo $SHELL`)
- The full output of the run
- What you expected to happen instead

If it's long or messy, a gist is perfect.

**Security-related problems** (anything involving credentials, downloads, or
system modification) — please don't open a public issue. See
[SECURITY.md](SECURITY.md) instead.

## Want to change something?

For anything beyond a typo fix, an issue first is appreciated — it saves you
from building something that won't get merged. Otherwise:

1. Fork, branch, make your change. One idea per pull request, please.
2. Make sure it passes the basics:

   ```sh
   bash -n update-go
   shellcheck update-go   # should come back clean
   ```

3. **Run the test suite.** It executes the real script inside an
   unprivileged user namespace with a fake `/usr/local`, so it's safe to run
   anywhere:

   ```sh
   tests/run.sh
   ```

   Even so, don't skip manual testing in a throwaway VM or container for
   anything that touches installation or profiles — the suite is thorough,
   but real systems are creative.
4. Don't hand-edit the `VERSION` placeholder near the top of `update-go`.
   The release workflow stamps the version in automatically when a release
   is cut; unstamped copies simply report `dev`.
5. Open the pull request with a short description of *why*, not just *what*.

## License

By contributing, you agree that your changes are released under the project's
[MIT License](LICENSE).
