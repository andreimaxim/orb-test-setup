# Orb Test Setup

A sample repository for testing cloud development environments — specifically
[Amp](https://ampcode.com) Orbs and [Claude Code](https://claude.ai/code) cloud
environments — with a Ruby project.

It contains a minimal Rails 8.1 API application on Ruby 4.0.6, backed by
PostgreSQL and Redis, used to verify that an agent sandbox can install a
toolchain, run database services, and execute a test suite against them.

## What the application does

Two endpoints, one per service:

| Endpoint          | Reads from                                        |
| ----------------- | ------------------------------------------------- |
| `GET /articles`   | PostgreSQL, directly                               |
| `GET /articles/1` | Redis on a hit, PostgreSQL on a miss               |

`Article.cached` is the whole of the second one:

```ruby
def self.cached(id)
  Rails.cache.fetch(cache_key_for(id), expires_in: 1.minute) do
    find(id).as_json
  end
end
```

`Rails.cache` is a `:redis_cache_store` in every environment, including test.
The test environment deliberately does *not* use `:null_store`, because a
suite that stubs the cache out cannot tell you whether Redis is running — and
that is exactly what this repository exists to check. Each parallel test worker
gets its own Redis namespace (keyed on its PID) alongside the numbered test
database Rails gives it, so workers cannot read each other's entries.

## How the environment is set up

There are two scripts, because starting a session and resuming one are not the
same problem.

`.agents/setup` runs when a session starts from scratch. It:

1. Installs PostgreSQL and Redis from the Ubuntu archives and starts both.
2. Creates a PostgreSQL superuser named after the current Unix user, so Rails
   can connect over the local socket with no password.
3. Downloads a precompiled Ruby 4.0.6 binary from
   [jdx/ruby](https://github.com/jdx/ruby), verifies its SHA-256 checksum and
   extracts it into `~/.local`.
4. Installs `bundler-audit` and runs `bundle install`.
5. Runs `bin/rails db:prepare` to create and migrate the development and test
   databases.

`.agents/resume` runs when a session that already exists wakes up again. It
starts PostgreSQL and Redis, and nothing else.

### Why the two are separate

The container filesystem is snapshotted once `.agents/setup` completes, so a
resumed session finds Ruby, the gems and the PostgreSQL data directory already
on disk. Reinstalling them would only add latency to every wake-up.

Processes are the part that does not survive. The sandbox is a Firecracker
microVM whose PID 1 is a supervisor rather than an init system —
`systemctl is-system-running` reports `offline` — so nothing restarts daemons
for you, and a database server left running before the container was reclaimed
is gone when the session resumes.

That is the division of labour: `.agents/setup` puts things on disk,
`.agents/resume` starts what has to be running.

Both scripts are safe to run more than once. `apt-get install` on an
already-installed package is a no-op, `service ... start` on a running service
exits 0, `createuser` failing on an existing role is swallowed, and
`db:prepare` migrates rather than recreates.

### Starting the services

`service postgresql start` and `service redis-server start` both work here.
There is no systemd, so `systemctl` fails — the `systemctl` binary is on the
image but has nothing to talk to — but `service` falls back to running the
SysV init script in `/etc/init.d` directly, which needs no init system.

`sudo` is required for both: the init scripts drop to the `postgres` and
`redis` users themselves.

Redis prints one harmless warning on startup, because its init script tries to
raise the open-file limit and the sandbox does not allow it:

```
/etc/init.d/redis-server: 51: ulimit: error setting limit (Operation not permitted)
```

It starts anyway and the script still exits 0.

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
on a local machine where Ruby and the databases are presumably already
installed. By the time Claude receives its first prompt the services are up,
the bundle is installed and the databases are migrated, so it can immediately
run `bin/rails test`.

Because both hooks are synchronous, `.agents/resume` is on the critical path of
every wake-up. Keep it to the few things that genuinely cannot survive a
container being reclaimed.

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

This is why `.agents/setup` runs `apt-get update || true`: the official Ubuntu
archives are refreshed successfully and only the PPA sources are denied, so the
subsequent `apt-get install` works even though `update` reported a failure. It
is also one reason the script downloads a prebuilt Ruby from GitHub releases
instead of installing it through `apt`.

## Running things

```sh
bin/rails test        # the suite, against orb_test_setup_test
bin/rails server      # http://localhost:3000/articles
bin/rails db:seed     # two rows to read back; idempotent
bin/ci                # gem audit, tests, and a seed replant
```

To exercise the parallel path — a separate database and Redis namespace per
worker — override the worker count, since the suite is under the threshold
where Rails parallelises on its own:

```sh
PARALLEL_WORKERS=4 bin/rails test
```
