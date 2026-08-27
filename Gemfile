# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The Carve parser gem (`carve-lang`) is a native extension over the carve-rs
# engine. It compiles its Rust extension at install time, so a Rust toolchain is
# required either way.
#
# carve-lang 0.1.2 published on 2026-08-27. The git source stays because it pins an exact
# revision rather than a floor, which is what caught #10; the ref below is the
# v0.1.2 tag commit for development while consumers resolve through the
# supported gemspec range.
#
# THE REF AND THE GEMSPEC FLOOR MOVE TOGETHER. Raising the floor to >= 0.1.1
# while this still pointed at a 0.1.0 revision made bundler unsatisfiable -
# "carve-lang >= 0.1.1 could not be found in carve-rb.git (at 57ded5f)" - and
# turned main red on Ruby 3.3. A floor is a claim about what resolves; the pin
# is what actually resolves here.
#
# PINNED to a revision. Without a ref this floated on whatever sat on the
# default branch at install time, and that is exactly how #10 happened: two AST
# renames landed upstream, this repo was not pushed for five days, and the badge
# stayed green on a stale run while a fresh install rendered bold text unstyled
# and dropped every footnote marker.
# THE SIBLING-CHECKOUT ESCAPE HATCH IS OPT-IN, and that is not a style
# preference. It used to trigger on `File.directory?`, so merely HAVING a
# carve-rb checkout beside this one silently replaced the pinned engine with
# whatever that working tree was parked on - no output, nothing in the diff, and
# a `Gemfile.lock` recording a PATH source that a contributor without the
# sibling never sees. Everything else in this file exists to make the engine a
# stated quantity; a directory that happens to exist must not be able to
# override it.
#
# markup-carve/jekyll-carve#3 measured the cost of the implicit form on the
# other Ruby satellite: with a sibling parked one day back, `bundle exec rspec`
# was 12 of 12 green while the engine under it still rendered
# `srcset="safe.png 1x, javascript:alert(1) 2x"` unsanitized, and bumping the
# `ref:` changed nothing because the ref branch was never taken.
#
# An env var has to be set on purpose, so the surprising resolution is the one
# you asked for. `script/verify_engine_pin.rb` reports it either way.
#
# WHY THERE IS NO COMMITTED Gemfile.lock. The usual answer to "CI resolved
# whatever the registry served" is a lockfile, and it is the wrong instrument
# twice over here. For the ENGINE it would be WEAKER than the `ref:` below: a
# lockfile entry names a VERSION (`carve-lang (0.1.1)`), the ref names a COMMIT,
# and two carve-rb builds can both call themselves 0.1.1. For everything else it
# would cost the oldest Ruby this gem supports - measured 2026-08-21,
# `bundle install` here writes `BUNDLED WITH 4.0.18`, bundler 4.0.x requires
# Ruby >= 3.2.0, and `ci.yml` runs a 3.1 leg while the gemspec says >= 3.0.0.
# `ruby/setup-ruby` installs the bundler the lockfile names, so committing one
# turns the 3.1 job red on a file nobody edited. A published gem also has no
# business shipping a lockfile: a consumer resolves through the gemspec range,
# never through this file. The rest of the bundle floats on purpose, and the
# `suite` job in `.github/workflows/engine-drift.yml` is what notices that.
carve_rb = ENV["CARVE_RB_PATH"]
if carve_rb && !carve_rb.empty?
  raise "CARVE_RB_PATH=#{carve_rb} is not a directory" unless File.directory?(carve_rb)

  gem "carve-lang", path: File.expand_path(carve_rb)
else
  gem "carve-lang", git: "https://github.com/markup-carve/carve-rb.git", ref: "b7f3a91a4192576de92894adf3ab3c5332199eff"  # v0.1.2
end
