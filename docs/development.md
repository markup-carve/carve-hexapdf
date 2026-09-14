# Development

## Setup and maintenance

```sh
bundle install
bundle exec rake test
```

### Which engine you are testing against

`bundle install` here does **not** resolve `carve-lang` from RubyGems. `Gemfile`
pins the engine to a carve-rb revision, so a development run measures one exact
engine build rather than whatever the registry serves that day:

```sh
bundle exec ruby script/verify_engine_pin.rb
# carve-lang 0.1.2 from carve-rb b7f3a91a... (Gemfile pins b7f3a91a4192)
```

CI runs that before the suite and refuses when the Gemfile, the resolved bundle
and the loaded library disagree. To develop against a local carve-rb checkout,
point `CARVE_RB_PATH` at it - it has to be set on purpose, so the surprising
resolution is the one you asked for:

```sh
CARVE_RB_PATH=../carve-rb bundle install
```

An installed copy of this gem resolves differently, through the range
`carve-hexapdf.gemspec` declares - today `>= 0.1.1, < 0.2.0`. The two are
deliberately not the same engine, and the difference is not academic: this gem
reads an AST whose node vocabulary was renamed once already inside 0.1.
`test/engine_floor_test.rb` asks whether the engine under `bundle exec rake
test` still publishes the vocabulary the renderer maps, and
`script/consumer_engine_probe.rb` asks the same of an actual `gem install` -
daily in `Engine drift`, and again before every release.

There is no committed `Gemfile.lock`, and that is deliberate; the reasoning,
including why a lockfile would be a weaker pin here and what it would cost the
Ruby 3.1 job, is at the top of `Gemfile`.
