# frozen_string_literal: true

require_relative "lib/carve/hexapdf/version"

Gem::Specification.new do |spec|
  spec.name = "carve-hexapdf"
  spec.version = Carve::Hexapdf::VERSION
  spec.authors = ["markup-carve"]
  spec.summary = "Render the Carve markup language to PDF via the pure-Ruby HexaPDF engine."
  spec.description = <<~DESC.strip
    Parse Carve markup (via the carve-lang gem) and render it to a laid-out PDF
    using HexaPDF's document composition engine. Carve block nodes map to
    HexaPDF text/list/table/container/image boxes; inline nodes map to styled
    text runs (bold/italic font variants, monospace code, colored links).
  DESC
  spec.homepage = "https://github.com/markup-carve/carve-hexapdf"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "CHANGELOG.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]

  # The Carve parser (native gem over carve-rs) provides Carve.parse.
  spec.add_dependency "carve-lang", ">= 0.1"
  # The pure-Ruby PDF composition engine. Dual-licensed AGPL-3.0 / commercial;
  # see README "Licensing".
  spec.add_dependency "hexapdf", ">= 1.0"

  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
