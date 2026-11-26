# Development

## Setup and maintenance

```sh
bundle install
bundle exec rake test
```

### Which engine you are testing against

On the Carve 0.2 line (`main`) no 0.2 `carve-lang` is released, so `Gemfile`
pins carve-rb by commit and bundler builds it from git (Rust and
libclang needed):

```sh
bundle exec ruby script/verify_engine_pin.rb
# carve-lang 0.1.14 from https://github.com/markup-carve/carve-rb (Gemfile pins carve-rb <sha>)
```

The gem version that commit carries is still `0.1.14`, so the gemspec range
admits it; the range moves when a 0.2 gem is published.

CI runs that before the suite and refuses when the Gemfile, the resolved bundle
and the loaded library disagree. To develop against a local carve-rb checkout,
point `CARVE_RB_PATH` at it - it has to be set on purpose, so the surprising
resolution is the one you asked for:

```sh
CARVE_RB_PATH=../carve-rb bundle install
```

An installed copy of this gem resolves differently, through the range
`carve-hexapdf.gemspec` declares - today `>= 0.1.1, < 0.2.0`. The two can
differ, and the difference is not academic: this gem
reads an AST whose node vocabulary was renamed once already inside 0.1.
`test/engine_floor_test.rb` asks whether the engine under `bundle exec rake
test` still publishes the vocabulary the renderer maps, and
`script/consumer_engine_probe.rb` asks the same of an actual `gem install` -
daily in `Engine drift`, and again before every release.

There is no committed `Gemfile.lock`, and that is deliberate: a bundler 4
lockfile would need Ruby 3.2 or newer, and CI still runs a 3.1 job.
