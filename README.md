# Orb Test Setup

A minimal Ruby 4.0.6 gem used to verify that Ruby projects work correctly in an Amp orb.

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
