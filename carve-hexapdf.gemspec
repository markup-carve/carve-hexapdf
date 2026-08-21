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
  #
  # THE FLOOR. >= 0.1.1 is the engine vocabulary this renderer is written for.
  # Measured through Carve.parse against both engines, 0.1.0 publishes the
  # pre-rename names: `*x*` is an `emphasis` node carrying a `kind` rather than
  # a `strong` node, `[^n]` is a `footnote` rather than a `footnote_ref`, and a
  # standalone image is a `block_image` rather than an `image`. See
  # test/engine_floor_test.rb, which checks the claim rather than restating it.
  #
  # The wording that used to stand here - about a list-valued URL attribute
  # rendered unsanitized - was inherited from the HTML siblings and does not
  # describe this gem. That defect is in the engine's HTML renderer; this gem
  # consumes the AST, and the AST carries a raw `javascript:` href in 0.1.0 and
  # 0.1.1 alike. The floor is kept where #23 put it, and it is a support claim,
  # so it moves only on a decision about what stopped working.
  #
  # THE CEILING follows from the engine's own versioning rather than from a
  # judgement about its API: on this org's 0.x line `0.1` is the major and the
  # third digit is the minor, so < 0.2.0 admits every engine minor (0.1.2,
  # 0.1.3, ...) and excludes only a release the engine itself declares
  # breaking. It is not a cap to relax at each engine minor; it is the point at
  # which someone has to look - and this gem reads an AST whose node vocabulary
  # HAS been renamed once already, mid-0.1, which is exactly what an unbounded
  # range would admit again unannounced. markup-carve/jekyll-carve carries the
  # same bound, so the siblings agree.
  spec.add_dependency "carve-lang", ">= 0.1.1", "< 0.2.0"
  # The pure-Ruby PDF composition engine. Dual-licensed AGPL-3.0 / commercial;
  # see README "Licensing".
  spec.add_dependency "hexapdf", ">= 1.0"

  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
