# Orb Test Setup

A sample repository for testing cloud development environments — specifically
[Amp](https://ampcode.com) Orbs and [Claude Code](https://claude.ai/code) cloud
environments — with a Ruby project.

It contains a minimal Ruby 4.0.6 gem used to verify that Ruby projects work
correctly in these environments.

## How the environment is set up

Both environments run the same setup script, `.agents/setup`, which:

1. Downloads a precompiled Ruby 4.0.6 binary from
   [jdx/ruby](https://github.com/jdx/ruby) and verifies its SHA-256 checksum.
2. Extracts it into `~/.local`.
3. Runs `bundle install` to install the gem's dependencies.

### The Claude Code hook

For Claude Code, the setup script is wired up via a `SessionStart` hook in
`.claude/settings.json`:

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
      }
    ]
  }
}
```

When a Claude Code session starts (`matcher: "startup"`), the hook checks the
`CLAUDE_CODE_REMOTE` environment variable and only runs `.agents/setup` when it
is `"true"` — i.e. only in Claude Code's remote cloud environment, not on a
local machine where Ruby is presumably already installed. By the time Claude
receives its first prompt, Ruby is installed and the bundle is ready, so it can
immediately run `rake test`.

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

The gem exposes one small method:

```ruby
require "orb/test/setup"

Orb::Test::Setup.hello # => "Hello from the orb!"
```
