# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The Carve parser gem (`carve-lang`) is a native extension over the carve-rs
# engine. It compiles its Rust extension at install time, so a Rust toolchain is
# required either way.
#
# carve-lang 0.1.1 published on 2026-08-18, so the note that used to stand here
# - that 0.1.1 was an unpublished draft and the git source was covering for it -
# no longer holds. The git source stays for now because it pins an exact
# revision rather than a floor, which is what caught #10; the ref below is the
# v0.1.1 tag's own commit, so development and a consumer install resolve the
# same engine.
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
carve_rb = File.expand_path("../carve-rb", __dir__)
if File.directory?(carve_rb)
  # A sibling checkout still wins for local development on carve-rb itself.
  gem "carve-lang", path: carve_rb
else
  gem "carve-lang", git: "https://github.com/markup-carve/carve-rb.git", ref: "f15f30a21e7a"  # v0.1.1
end
