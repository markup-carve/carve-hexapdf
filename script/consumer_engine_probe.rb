#!/usr/bin/env ruby
# frozen_string_literal: true

# WHAT DOES AN INSTALL OF THIS GEM ACTUALLY RENDER?
#
# `Gemfile` pins the engine by carve-rb revision, so no ordinary run in this
# repository ever resolves `carve-lang` from RubyGems. A consumer only ever
# does. Those are different engines, and this repository has already been bitten
# by the difference (#10) - which is why the question is asked of an INSTALLED
# gem in an isolated GEM_HOME rather than of the checkout.
#
# Run it with GEM_HOME pointing at a prefix where the built `carve-hexapdf` gem
# has been installed, so RubyGems resolved `carve-lang` through the range the
# gemspec declares. It is used by two jobs that ask the question for different
# reasons:
#
#   * `.github/workflows/release.yml` - before publishing, because the floor and
#     the ceiling are claims about what a consumer resolves and this is the only
#     way to check them rather than restate them.
#   * `.github/workflows/engine-drift.yml` - daily, because pinning every
#     routine run makes each one reproducible and the repository blind. No
#     pinned run ever meets a carve-lang published after the pin. This is the
#     run that does, a day after a release rather than in whoever's pull request
#     happens to be next.

GEM = "carve-hexapdf"
ENGINE = "carve-lang"

def refuse(message)
  warn "::error::#{message}"
  exit 1
end

# THE CONSUMER'S OWN ORDER, and it is load-bearing. Activating carve-hexapdf
# first means RubyGems picks carve-lang through the range the gemspec declares,
# the way `require "carve/hexapdf"` does in a user's project. Requiring "carve"
# on its own would activate the NEWEST carve-lang the environment can see, which
# is a different question and would report an engine no consumer resolves.
begin
  gem GEM
  require "carve/hexapdf"
rescue Gem::LoadError, LoadError => e
  refuse "#{GEM} does not load in GEM_HOME=#{ENV.fetch('GEM_HOME', '(unset)')}: #{e.message}"
end

# --- Did the declared range govern this install? -----------------------------

begin
  installed = Gem::Specification.find_by_name(GEM)
rescue Gem::MissingSpecError
  refuse "#{GEM} is not installed in GEM_HOME=#{ENV.fetch('GEM_HOME', '(unset)')}, so nothing " \
         "here resolved through the gemspec and this probe would be measuring some other engine"
end

dependency = installed.dependencies.find { |d| d.name == ENGINE }
refuse "the installed #{GEM} #{installed.version} declares no #{ENGINE} dependency" if dependency.nil?

resolved = Gem::Version.new(Carve::VERSION)

# A BACKSTOP, not the mechanism. The activation above is what makes the range
# govern; this reports the case where it did not - a stray carve-lang activated
# earlier, or a probe run outside the isolated GEM_HOME it was meant for.
unless dependency.requirement.satisfied_by?(resolved)
  refuse "#{GEM} #{installed.version} declares #{ENGINE} #{dependency.requirement}, but " \
         "#{resolved} is what loaded - the probe is not reading the install it thinks it is"
end

puts "#{GEM} #{installed.version} declares #{ENGINE} #{dependency.requirement}; " \
     "this install resolved #{resolved}"

# --- Does that engine still speak the vocabulary this renderer maps? ---------
#
# The same three node kinds test/engine_floor_test.rb checks, asked of the
# engine a CONSUMER resolves rather than of the pinned one. A renamed node does
# not raise here: it falls through to a compatibility arm or to the default
# branch, and the content reaches the page unstyled or not at all. That is
# precisely why it has to be asserted rather than inferred from a render that
# did not crash.
VOCABULARY = {
  "a *bold* word" => "strong",
  "a note[^n]\n\n[^n]: text\n" => "footnote_ref",
  "![alt](x.png)" => "image",
}.freeze

def node_types(node, acc = [])
  case node
  when Hash
    acc << node[:type] if node[:type]
    node.each_value { |v| node_types(v, acc) if v.is_a?(Array) || v.is_a?(Hash) }
  when Array
    node.each { |c| node_types(c, acc) }
  end
  acc
end

VOCABULARY.each do |source, want|
  got = node_types(Carve.parse(source))
  next if got.include?(want)

  refuse "the engine a consumer resolves (#{ENGINE} #{resolved}) publishes no #{want.inspect} " \
         "node for #{source.inspect}; it published #{got.uniq.inspect}"
end

# --- And does a document still reach a page through it? ----------------------
#
# Checked LAST and separately: the vocabulary assertions above would all hold
# over an engine whose output this renderer could no longer draw, and a probe
# that only inspected node names would report a healthy engine while every PDF
# came out empty.
pdf = Carve::Hexapdf.render(<<~CARVE)
  # Heading

  A *bold* word, a /slanted/ one, and a note[^n].

  [^n]: the note
CARVE

refuse "the render produced #{pdf.bytesize} bytes, which is not a PDF" if pdf.bytesize < 512
refuse "the render does not start with a PDF header: #{pdf[0, 16].inspect}" unless pdf.start_with?("%PDF-")

puts "#{ENGINE} #{resolved} -> #{pdf.bytesize} bytes of PDF, vocabulary #{VOCABULARY.values.inspect} present"
