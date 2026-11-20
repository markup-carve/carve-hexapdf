# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# On the Carve 0.2 line the engine is carve-rb `next2` at a pinned commit,
# built from git (Rust and libclang needed), because no 0.2 carve-lang is
# released yet. On `main` it is the released gem at an exact version.
#
# The pin and the gemspec floor are different claims: the floor is the oldest
# engine this gem works with, the pin is the engine the suite measures. They
# must still agree - a pin below the floor makes bundler unsatisfiable.
# `script/verify_engine_pin.rb` reads the pin back in CI.
#
# CARVE_RB_PATH swaps in a local carve-rb checkout. It is opt-in, because a
# sibling checkout that merely existed used to replace the pinned engine
# silently (markup-carve/jekyll-carve#3), and verify_engine_pin.rb refuses a run
# that used it.
#
# There is no committed Gemfile.lock: bundler 4 lockfiles need Ruby >= 3.2, and
# CI still runs a 3.1 leg. The rest of the bundle floats on purpose, and the
# `suite` job in `.github/workflows/engine-drift.yml` notices when it moves.
carve_rb = ENV["CARVE_RB_PATH"]
if carve_rb && !carve_rb.empty?
  raise "CARVE_RB_PATH=#{carve_rb} is not a directory" unless File.directory?(carve_rb)

  gem "carve-lang", path: File.expand_path(carve_rb)
else
  gem "carve-lang", git: "https://github.com/markup-carve/carve-rb", ref: "ca957d13fa9a2c83329298c4350be92ddff76cbb"
end
