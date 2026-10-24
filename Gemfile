# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The engine is the RELEASED carve-lang gem at an exact version, so a
# development run measures a version a consumer can install. It used to be a
# carve-rb git revision; released versions replaced that once carve-rb shipped
# precompiled gems on every platform CI runs. carve-lang 0.1.12 also carries
# the `substitution` halves the renderer reads (#39).
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
  gem "carve-lang", "0.1.12"
end
