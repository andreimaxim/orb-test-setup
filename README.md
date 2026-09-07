# Orb Test Setup

A sample repository for testing cloud development environments — specifically
[Claude Code](https://claude.ai/code) cloud environments and
[Amp](https://ampcode.com) Orbs — with a Ruby project.

It contains a minimal Rails 8.1 API application on Ruby 4.0.6, backed by
PostgreSQL and Redis, used to verify that an agent sandbox can install a
toolchain, run database services, execute a test suite against them, and
receive an environment variable — `RAILS_MASTER_KEY` — from its host.

## What the application does

| Endpoint          | Reads from                                          |
| ----------------- | --------------------------------------------------- |
| `GET /articles`   | PostgreSQL, directly                                 |
| `GET /articles/1` | Redis on a hit, PostgreSQL on a miss                 |
| `GET /status`     | all three, in one request                            |

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

### The status endpoint

`GET /status` is the one to curl after a sandbox comes up. It queries
PostgreSQL, round trips a token through Redis, and decrypts a value out of
`config/credentials.yml.enc`, then answers 200 only if all three worked:

```json
{
  "ok": true,
  "checks": {
    "postgres": { "ok": true, "articles": 2 },
    "redis": { "ok": true },
    "credentials": { "ok": true, "canary": "the master key reached the sandbox" }
  }
}
```

A broken dependency turns its own entry false and the response into a 503,
while the others keep reporting honestly — stop PostgreSQL and Redis still
says `ok`. `curl --fail` is therefore a usable one-line smoke test:

```sh
curl --fail --silent http://localhost:3000/status
```

Failures name themselves where they can. A dead PostgreSQL raises, so its entry
carries the exception:

```json
"postgres": { "ok": false, "error": "ActiveRecord::ConnectionNotEstablished: connection to server on socket ..." }
```

Redis is quieter, because `Rails.cache` swallows connection errors and returns
nil rather than raising. There is no exception to report, so the probe simply
does not come back and the entry is `{ "ok": false }`. A missing master key is
the same kind of quiet: the credentials read back empty and `canary` comes out
`null`.

This is what makes the master key load-bearing rather than decorative — the
app itself reads it on every status request. See [Environment
variables](#environment-variables).

Note that `/status` is not the same as Rails' generated `/up`, which stays
where it is. `/up` returns 200 as soon as the app boots without raising, and
knows nothing about whether its dependencies answer.

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

## Environment variables

This application needs one, and a session that does not have it fails:

```
RAILS_MASTER_KEY=07526d26a503c97bfbd0912247d225f3
```

Rails encrypts `config/credentials.yml.enc` with a master key, which it reads
from `config/master.key` if that file is there and otherwise from
`RAILS_MASTER_KEY`. The encrypted file is committed; the key file is
gitignored, which is the arrangement Rails ships — the encrypted file is
useless to anyone without the key, so a checkout can carry its secrets around
without exposing them. `RAILS_MASTER_KEY` is still the variable's name as of
Rails 8.1.

A fresh clone therefore has no key file, and only the environment variable can
supply one. That is what makes this worth testing, and the third thing worth
testing about a sandbox after "can it install things" and "can it keep a daemon
running": does a variable configured on the host actually reach the session?

**Publishing a master key is normally the one thing you must not do.** This one
is published on purpose, because the repository is a test fixture: the
credentials file behind it holds a generated `secret_key_base` and a canary
string, for an application that is never deployed and has no sessions, no
users and no third-party API keys. Treat the value as a fixture, not as a
secret. If you fork this into something real, run `bin/rails credentials:edit`
to write a fresh file and generate a new key, and never paste that one
anywhere.

### Setting RAILS_MASTER_KEY in a Claude Code cloud environment

Environment variables belong to the *environment*, not the repository. At
[claude.ai/code](https://claude.ai/code), select the cloud icon showing the
current environment's name in the row above the message box, then hover the
environment and select the settings icon (or **Add cloud environment** for a
new one). The dialog has an **Environment variables** box that takes `.env`
format, one pair per line:

```
RAILS_MASTER_KEY=07526d26a503c97bfbd0912247d225f3
```

Save, then start a **new** session. A session copies the environment's
variables once, at startup, so a session that is already running keeps the
values it started with and will not see the change.

The dialog warns that anyone who uses the environment can read these values,
which is exactly why a fixture key is the right thing to paste there and a
production key is not. Pro and Max plans offer **API credentials** as the
alternative for real secrets, but that mechanism only attaches a key to
outbound HTTP requests through the agent proxy — `RAILS_MASTER_KEY` is read by
the app itself, so it cannot use it. A real Rails app in a shared sandbox wants
a throwaway key for a throwaway credentials file, not its production one.

For an Amp orb, set the same variable wherever that orb configures its
environment; the mechanism the app cares about is only that
`RAILS_MASTER_KEY` is exported in the shell that runs `bin/rails`.

### What happens when the key is missing

Two things notice, and nothing else does. `GET /status` reports the canary
back, or `null` with the whole response downgraded to a 503:

```json
"credentials": { "ok": false, "canary": null }
```

And `test/credentials_test.rb` decrypts the file and asserts on the canary, so
a missing key is a test failure with a message rather than a mystery:

```
Failure:
CredentialsTest#test_the_encrypted_credentials_can_be_decrypted
could not decrypt config/credentials.yml.enc — set RAILS_MASTER_KEY, see README.md
```

Setup is not one of them. `.agents/setup` succeeds without the key, because
`bundle install` and `db:prepare` never touch credentials, and Rails falls back
to `tmp/local_secret.txt` for `secret_key_base` outside production. A sandbox
missing the variable looks perfectly healthy until something asks.

To work on the repository locally, either export the variable or write the key
to the file the way Rails expects:

```sh
echo 07526d26a503c97bfbd0912247d225f3 > config/master.key
```

Both paths are tested; `config/master.key` stays gitignored either way.

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

Sixteen tests, one group per thing the sandbox has to get right: `test/models`
and `test/controllers/articles_controller_test.rb` for PostgreSQL and Redis,
`test/credentials_test.rb` for `RAILS_MASTER_KEY`, and
`test/controllers/status_controller_test.rb` for all three at once, including
what the endpoint does when a dependency is genuinely unreachable.

With a server running, the same check in one line:

```sh
curl --fail --silent http://localhost:3000/status
```

To exercise the parallel path — a separate database and Redis namespace per
worker — override the worker count, since the suite is under the threshold
where Rails parallelises on its own:

```sh
PARALLEL_WORKERS=4 bin/rails test
```
