# Orb Test Setup

A sample repository for testing cloud development environments — specifically
[Amp](https://ampcode.com) Orbs and [Claude Code](https://claude.ai/code) cloud
environments — with a Ruby project.

It contains a minimal Ruby 4.0.6 gem used to verify that Ruby projects work
correctly in these environments.

## How the environment is set up

There are two scripts, because starting a session and resuming one are not the
same problem.

`.agents/setup` runs when a session starts from scratch. It:

1. Downloads a precompiled Ruby 4.0.6 binary from
   [jdx/ruby](https://github.com/jdx/ruby) and verifies its SHA-256 checksum.
2. Extracts it into `~/.local`.
3. Runs `bundle install` to install the gem's dependencies.

`.agents/resume` runs when a session that already exists wakes up again. It:

1. Checks that Ruby and the bundled gems are still on disk, falling back to
   `.agents/setup` if they are not.
2. Starts any long-running service the project needs. This project has none,
   but see [Restarting services](#restarting-services) below.

### Why the two are separate

The container filesystem is snapshotted once `.agents/setup` completes, so a
resumed session normally finds Ruby and the gems already installed. Downloading
and extracting Ruby again would only add latency to every wake-up.

Processes are the part that does not survive. The sandbox is a Firecracker
microVM whose PID 1 is a supervisor rather than an init system —
`systemctl is-system-running` reports `offline` — so nothing restarts daemons
for you, and a database server left running before the container was reclaimed
is gone when the session resumes.

That is the division of labour: `.agents/setup` puts things on disk,
`.agents/resume` checks that disk state and starts what has to be running.

### The Claude Code hooks

Both scripts are wired up through `SessionStart` hooks in
`.claude/settings.json`. The event fires with a `source` of `startup`,
`resume`, `clear` or `compact`, and the `matcher` field selects which of those
each hook responds to:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "if [ \"${CLAUDE_CODE_REMOTE:-}\" = \"true\" ]; then bash \"$CLAUDE_PROJECT_DIR/.agents/setup\"; fi"
          }
        ]
      },
      {
        "matcher": "resume",
        "hooks": [
          {
            "type": "command",
            "command": "if [ \"${CLAUDE_CODE_REMOTE:-}\" = \"true\" ]; then bash \"$CLAUDE_PROJECT_DIR/.agents/resume\"; fi"
          }
        ]
      }
    ]
  }
}
```

Both hooks check the `CLAUDE_CODE_REMOTE` environment variable and only run
when it is `"true"` — i.e. only in Claude Code's remote cloud environment, not
on a local machine where Ruby is presumably already installed. By the time
Claude receives its first prompt, Ruby is installed and the bundle is ready, so
it can immediately run `rake test`.

Because both hooks are synchronous, `.agents/resume` is on the critical path of
every wake-up. Keep its checks cheap so the warm case short-circuits quickly.

### Restarting services

A project that depends on a database server starts it from `.agents/resume`,
guarded so that the script stays safe to run more than once:

```sh
if ! pg_isready --quiet; then
  pg_ctl --pgdata "$PGDATA" --log "$PGDATA/server.log" start
fi
```

Start daemons directly, with `pg_ctl` or the binary itself. `systemctl start
postgresql` and `service postgresql start` do not work here: the `systemctl`
binary exists on the image, but there is no systemd running for it to talk to.

## Network access caveats

Claude Code cloud environments with "trusted" network access only allow
traffic to an allowlist of known hosts. Notably, Launchpad PPAs are blocked, so
`apt update` fails with exit code 100:

```
Err:1  ppa.launchpadcontent.net .../deadsnakes    ← denied
Err:2  ppa.launchpadcontent.net .../ondrej/php    ← denied
Hit:3  security.ubuntu.com noble-security
Hit:4  download.docker.com  noble
Hit:5  archive.ubuntu.com   noble
Hit:6  archive.ubuntu.com   noble-updates
Hit:7  archive.ubuntu.com   noble-backports
--- exit: 100 ---
```

The official Ubuntu archives (and other allowlisted hosts such as
`download.docker.com`) still work — only the PPA sources are denied. This is
one reason the setup script downloads a prebuilt Ruby from GitHub releases
instead of installing it through `apt`.

## Test

Run the test suite:

```sh
rake test
```
