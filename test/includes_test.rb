# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "carve/hexapdf"

# Include expansion, contained to a root, before the AST reaches HexaPDF.
#
# The document is drawn from `Carve.parse_with_includes` rather than from HTML,
# so what these assert on is the text that ends up in the PDF.
class IncludesTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("carve-hexapdf-inc")
    FileUtils.mkdir_p(File.join(@root, "doc", "sub"))
    FileUtils.mkdir_p(File.join(@root, "outside"))
    write("doc/sub/frag.crv", "Fragment body here.\n")
    write("outside/secret.crv", "Uncontained body here.\n")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(relative, body)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def text_of(bytes)
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    doc.pages.map { |page| page.contents.to_s }.join
  end

  # HexaPDF writes the glyphs of a standard font as literal strings, so the
  # words are readable in the content stream. Drawn text is what proves a
  # fragment was expanded, rather than the AST that produced it.
  def assert_drawn(bytes, words)
    content = text_of(bytes)
    words.each { |word| assert_includes content, word }
  end

  def refute_drawn(bytes, words)
    content = text_of(bytes)
    words.each { |word| refute_includes content, word }
  end

  def quiet
    previous = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = previous
  end

  # --- the switch ----------------------------------------------------------

  def test_a_string_leaves_the_directive_literal
    # The drawn text alone cannot tell "never expanded" from "expanded against
    # some root and found nothing" - both leave the directive standing. The
    # silence is what separates them: an attempted resolution that failed says
    # so, so a String that says nothing was never resolved at all.
    bytes = nil
    messages = quiet { bytes = Carve::Hexapdf.render("{{ sub/frag.crv }}\n") }
    assert_drawn bytes, %w[frag.crv]
    refute_drawn bytes, %w[Fragment]
    assert_equal "", messages
  end

  def test_render_file_leaves_the_directive_literal
    out = File.join(@root, "out.pdf")
    Carve::Hexapdf.render_file("{{ sub/frag.crv }}\n", out)
    refute_drawn File.binread(out), %w[Fragment]
  end

  def test_a_named_input_file_expands
    page = write("doc/index.crv", "{{ sub/frag.crv }}\n")
    assert_drawn Carve::Hexapdf.render_from_file(page), %w[Fragment]
  end

  def test_an_explicit_root_expands_a_string
    page = write("doc/index.crv", "placeholder\n")
    bytes = Carve::Hexapdf.render("{{ sub/frag.crv }}\n",
                                  include_root: File.join(@root, "doc"),
                                  source_path: page)
    assert_drawn bytes, %w[Fragment]
  end

  # --- the root ------------------------------------------------------------

  def test_containment_defaults_to_the_input_files_directory
    page = write("doc/index.crv", "{{ ../outside/secret.crv }}\n")
    bytes = quiet_render(page)
    refute_drawn bytes, %w[Uncontained]
  end

  def test_a_named_root_widens_containment
    page = write("doc/index.crv", "{{ ../outside/secret.crv }}\n")
    bytes = Carve::Hexapdf.render_from_file(page, include_root: @root)
    assert_drawn bytes, %w[Uncontained]
  end

  def test_a_relative_root_is_refused_rather_than_resolved
    page = write("doc/index.crv", "{{ sub/frag.crv }}\n")
    error = assert_raises(ArgumentError) do
      Carve::Hexapdf.render_from_file(page, include_root: "doc")
    end
    assert_match(/absolute/, error.message)
  end

  # --- denials -------------------------------------------------------------

  def test_a_refusal_is_reported
    page = write("doc/index.crv", "{{ ../outside/secret.crv }}\n")
    messages = quiet { Carve::Hexapdf.render_from_file(page) }
    assert_includes messages, "include-unresolved"
  end

  def test_the_report_does_not_say_which_denial_it_was
    page = write("doc/index.crv", "{{ ../outside/secret.crv }}\n")
    messages = quiet { Carve::Hexapdf.render_from_file(page) }
    refute_includes messages, "outside-root"
  end

  def test_the_denial_class_reaches_a_caller_that_asks
    page = write("doc/index.crv", "{{ ../outside/secret.crv }}\n\n{{ nope.crv }}\n")
    report = nil
    Carve::Hexapdf.render_from_file(page, on_includes: ->(**kwargs) { report = kwargs })
    denials = report[:dependencies].map { |dependency| dependency[:denial] }
    assert_includes denials, "outside-root"
    assert_includes denials, "not-found"
  end

  def test_a_caller_that_asks_gets_the_dependency_identities
    page = write("doc/index.crv", "{{ sub/frag.crv }}\n")
    report = nil
    Carve::Hexapdf.render_from_file(page, on_includes: ->(**kwargs) { report = kwargs })
    assert_equal [{ denial: nil, path: "sub/frag.crv", resolved: true }],
                 report[:dependencies]
  end

  def test_a_caller_that_asks_is_the_only_one_reporting
    page = write("doc/index.crv", "{{ nope.crv }}\n")
    messages = quiet do
      Carve::Hexapdf.render_from_file(page, on_includes: ->(**) {})
    end
    assert_equal "", messages
  end

  def test_no_host_path_reaches_a_reported_message
    page = write("doc/sub/page.crv", "{{ nope.crv }}\n")
    messages = quiet { Carve::Hexapdf.render_from_file(page) }
    assert_includes messages, "include-unresolved"
    refute_includes messages, @root
  end

  # --- what the engine is asked to do --------------------------------------

  def test_a_path_resolves_against_the_page_that_wrote_it
    write("doc/sub/sibling.crv", "Sibling body here.\n")
    page = write("doc/sub/page.crv", "{{ sibling.crv }}\n")
    assert_drawn Carve::Hexapdf.render_from_file(page, include_root: File.join(@root, "doc")),
                 %w[Sibling]
  end

  def test_a_nested_path_resolves_against_the_including_file
    write("doc/sub/deep/inner.crv", "Innermost body here.\n")
    write("doc/sub/frag.crv", "{{ deep/inner.crv }}\n")
    page = write("doc/index.crv", "{{ sub/frag.crv }}\n")
    assert_drawn Carve::Hexapdf.render_from_file(page), %w[Innermost]
  end

  def test_a_cycle_degrades_instead_of_hanging
    write("doc/a.crv", "Alpha {{ b.crv }}\n")
    write("doc/b.crv", "Beta {{ a.crv }}\n")
    page = write("doc/index.crv", "{{ a.crv }}\n")
    messages = nil
    bytes = nil
    messages = quiet { bytes = Carve::Hexapdf.render_from_file(page) }
    assert_drawn bytes, %w[Alpha Beta]
    assert_includes messages, "include-cycle"
  end

  def test_a_missing_target_leaves_the_directive_drawn
    page = write("doc/index.crv", "{{ nope.crv }}\n")
    bytes = quiet_render(page)
    assert_drawn bytes, %w[nope.crv]
  end

  # --- parent and child share one parse ------------------------------------

  def test_the_profile_governs_the_childs_parse_too
    write("doc/sub/frag.crv", "# Headline in child\n")
    page = write("doc/index.crv", "{{ sub/frag.crv }}\n")
    # `minimal` denies headings, so the child's marker survives as text.
    assert_drawn Carve::Hexapdf.render_from_file(page, profile: "minimal"), ["# Headline"]
    # `article` allows them, and the same child parses as a heading.
    refute_drawn Carve::Hexapdf.render_from_file(page, profile: "article"), ["# Headline"]
  end

  def test_the_extension_set_governs_the_childs_parse_too
    write("doc/sub/frag.crv", "See https://example.com for more.\n")
    page = write("doc/index.crv", "{{ sub/frag.crv }}\n")
    # The drawn text is the same either way; what changes is whether the child's
    # bare URL became a link, and a link becomes a URI annotation in the PDF.
    assert_equal 0, link_count(Carve::Hexapdf.render_from_file(page))
    assert_equal 1,
                 link_count(Carve::Hexapdf.render_from_file(page, extensions: ["autolink"]))
  end

  def link_count(bytes)
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    doc.pages.sum { |page| Array(page[:Annots]).count { |a| a[:Subtype] == :Link } }
  end

  def test_parse_options_without_a_root_are_refused_rather_than_dropped
    error = assert_raises(ArgumentError) do
      Carve::Hexapdf.render("# x\n", extensions: ["math_block"])
    end
    assert_match(/include path only/, error.message)
  end

  def quiet_render(page, **opts)
    bytes = nil
    quiet { bytes = Carve::Hexapdf.render_from_file(page, **opts) }
    bytes
  end
end
