# Orb Test Setup

A minimal Rails 8.1 API application for testing
[Claude Code](https://claude.ai/code) cloud environments and
[Amp](https://ampcode.com) orbs.

The project uses Ruby 4.0.6, PostgreSQL, and Redis to check whether a sandbox
can install a toolchain, run database services, execute tests, and receive
`RAILS_MASTER_KEY` from its host.

## Running the project

First complete [environment setup](#environment-setup) and supply the
[fixture master key](#environment-variables). Then run:

```sh
bin/rails test        # the suite, against orb_test_setup_test
bin/rails server      # http://localhost:3000/articles
bin/rails db:seed     # two rows to read back; idempotent
bin/ci                # gem audit, tests, and a seed replant
```

Seed the database before inspecting the article endpoints. `bin/ci` runs
setup, the gem audit, tests, and a test-database seed replant.

The sixteen tests cover PostgreSQL and Redis in `test/models` and
`test/controllers/articles_controller_test.rb`, credentials in
`test/credentials_test.rb`, and dependency health and failures in
`test/controllers/status_controller_test.rb`.

To test separate databases and Redis namespaces per worker, override the
worker count. The suite is otherwise below Rails' parallelization threshold:

```sh
PARALLEL_WORKERS=4 bin/rails test
```

## What the application does

| Endpoint          | Checks or reads from                        |
| ----------------- | ------------------------------------------- |
| `GET /articles`   | PostgreSQL                                  |
| `GET /articles/1` | Redis on a cache hit, PostgreSQL on a miss   |
| `GET /status`     | PostgreSQL, Redis, and encrypted credentials |

`Article.cached` implements the cached read:

```ruby
def self.cached(id)
  Rails.cache.fetch(cache_key_for(id), expires_in: 1.minute) do
    find(id).as_json
  end
end
```

`Rails.cache` is a `:redis_cache_store` in every environment, including test.
Tests use real Redis rather than `:null_store` so they detect a missing cache
server. Each parallel worker has a Redis namespace keyed on its PID and a
numbered test database, so workers cannot read each other's entries.

### The status endpoint

Use `GET /status` to check a running sandbox. It queries PostgreSQL, writes
and reads a token through Redis, and reads a value from
`config/credentials.yml.enc`. It returns 200 only if all three checks pass:

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

A failed check sets its own `ok` to false and the response status to 503.
The other checks still report independently. With a server running, use
`curl --fail` as a smoke test:

```sh
curl --fail --silent http://localhost:3000/status
```

Exceptions appear in the affected check's `error` field. For example, an
unreachable PostgreSQL server reports:

```json
"postgres": { "ok": false, "error": "ActiveRecord::ConnectionNotEstablished: connection to server on socket ..." }
```

`Rails.cache` swallows connection errors and returns nil, so an unreachable
Redis server usually reports `{ "ok": false }` without an exception. A
missing master key leaves credentials empty and `canary` null. See
[Environment variables](#environment-variables).

Rails' generated `/up` endpoint only checks that the app boots without
raising. Use `/status` when you need to check its dependencies too.

## Environment setup

The repository has separate scripts for initial setup and resume.

`.agents/setup` runs when a session starts from scratch. It:

1. Installs PostgreSQL and Redis with apt and starts both.
2. Creates a PostgreSQL superuser named after the current Unix user, so Rails
   can connect over the local socket with no password.
3. Installs [mise](https://mise.jdx.dev), activates its shims, trusts the
   project config, and runs `mise install` to download and verify Ruby.
   `mise.toml` enables the idiomatic `.ruby-version` file as the source of
   truth. Setup also appends shim activation to `~/.bashrc` for future
   interactive Bash shells.
4. Runs `bundle install` to install the gems, including `bundler-audit`.
5. Runs `bin/rails db:prepare` to create and migrate the development and test
   databases.

`mise trust` approves the config. The remaining commands install Ruby, gems,
and database services.

`.agents/resume` starts PostgreSQL and Redis when an existing session wakes.
It does not reinstall dependencies.

### Why the two are separate

The filesystem snapshot preserves Ruby, gems, and PostgreSQL data, but not
running processes. The sandbox has no active systemd instance to restart
database servers, so resume starts them explicitly. Keep resume limited to
what must run again after wake-up.

Both scripts are safe to run more than once. `apt-get install` on an
already-installed package is a no-op. Setup runs every installation step
unconditionally and lets the installers handle existing installations.
`service ... start` on a running service exits 0, `createuser` failing on an
existing role is swallowed, and `db:prepare` migrates rather than recreates.

### Starting the services

Use `sudo service postgresql start` and `sudo service redis-server start`.
`service` runs the SysV scripts in `/etc/init.d` without an active systemd
instance. The scripts require sudo and run the daemons as `postgres` and
`redis` respectively.

Redis may print a warning because the sandbox prevents its init script from
raising the open-file limit:

```
/etc/init.d/redis-server: 51: ulimit: error setting limit (Operation not permitted)
```

Redis still starts, and the script exits 0.

### The Claude Code hooks

[`SessionStart` hooks](.claude/settings.json) run `.agents/setup` for
`startup` and `.agents/resume` for `resume`. Neither runs for `clear` or
`compact`.

Both hooks require `CLAUDE_CODE_REMOTE=true`, so local Claude Code sessions
do not install tools or start database services. The hooks are synchronous:
setup finishes before Claude receives its first prompt, and resume finishes
before a resumed session continues.

## Environment variables

The application needs `RAILS_MASTER_KEY` to decrypt its credentials.

**This is a public test fixture, not a production key.** The credentials hold
a generated `secret_key_base` and a canary string. The app has no users,
sessions, or third-party API keys and is never deployed. If you adapt it for
a real application, generate a fresh key and credentials with
`bin/rails credentials:edit`. Never publish the replacement key.

```
RAILS_MASTER_KEY=07526d26a503c97bfbd0912247d225f3
```

Rails reads the key from `RAILS_MASTER_KEY` first, falling back to
`config/master.key` when the variable is unset or blank. The encrypted
`config/credentials.yml.enc` is committed, but `config/master.key` is
gitignored. A fresh cloud checkout therefore tests whether the host passes
the environment variable into the session.

### Setting RAILS_MASTER_KEY in a Claude Code cloud environment

1. At [claude.ai/code](https://claude.ai/code), select the cloud icon showing
   the current environment's name above the message box.
2. Hover over the environment and select its settings icon, or choose
   **Add cloud environment** to create one.
3. Paste the fixture assignment above into **Environment variables**. The
   field accepts `.env` format, one assignment per line.
4. Save and start a new session. Existing sessions retain the variables they
   received at startup.

Anyone using the environment can read these values. Use disposable fixture
credentials, not production secrets. The **API credentials** option attaches
keys to outbound HTTP requests through the agent proxy. It cannot supply
`RAILS_MASTER_KEY`, which the app reads from its process environment.

For an Amp orb, configure the same variable in the orb's environment. It must
be exported to the shell that runs `bin/rails`.

### Local development

Export `RAILS_MASTER_KEY` using the fixture value above, or write the key to
Rails' gitignored key file:

```sh
echo 07526d26a503c97bfbd0912247d225f3 > config/master.key
```

Both methods are supported. Keep `config/master.key` out of version control.

### What happens when the key is missing

`GET /status` returns 503 with a null canary:

```json
"credentials": { "ok": false, "canary": null }
```

The credentials tests also fail with an explicit message:

```
Failure:
CredentialsTest#test_the_encrypted_credentials_can_be_decrypted
could not decrypt config/credentials.yml.enc — set RAILS_MASTER_KEY, see README.md
```

Setup can still succeed without the key: `bundle install` and `db:prepare`
do not need the encrypted values, and Rails can use `tmp/local_secret.txt`
for `secret_key_base` outside production. Run the tests or check `/status`
to verify that credentials reached the session.

## Network access caveats

Claude Code's "trusted" network mode restricts traffic to an allowlist.
In the Ubuntu cloud image tested with this repository, Launchpad PPAs were
blocked while the official Ubuntu archives remained accessible:

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

Setup uses `apt-get update || true` to continue past those PPA failures.
The following `apt-get install` still fails if required packages cannot be
installed. Mise downloads precompiled Ruby from GitHub releases rather than
installing it through apt.
