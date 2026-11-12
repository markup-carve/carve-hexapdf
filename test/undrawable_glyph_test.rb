# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "carve/hexapdf"

# Text the run font cannot draw must not lose the document (carve-hexapdf#70).
#
# Under the default standard Type1 fonts, `<=` became the smart-typography glyph
# U+2264, which Times has but WinAnsi cannot encode, and render_file raised.
class UndrawableGlyphTest < Minitest::Test
  class TextCollector < HexaPDF::Content::Processor
    attr_reader :text

    def initialize(resources)
      super
      @text = +""
    end

    def show_text(str)
      @text << decode_text(str)
    end
    alias show_text_with_positioning show_text
  end

  INTER = File.join(HexaPDF.data_dir, "fonts", "Inter-Regular.ttf")

  def page_text(path)
    doc = HexaPDF::Document.open(path)
    doc.pages.map do |page|
      collector = TextCollector.new(page.resources)
      page.process_contents(collector)
      collector.text
    end.join
  end

  # The README path: render_file on source text, default fonts.
  def render(source, **opts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.pdf")
      Carve::Hexapdf.render_file(source, path, **opts)
      page_text(path)
    end
  end

  def test_comparison_operators_fall_back_to_the_source_spelling
    assert_equal "Use x <= 10, y >= 2, a != b here.",
                 render("Use x <= 10, y >= 2, a != b here.\n")
  end

  def test_a_glyph_the_font_encodes_is_kept
    assert_equal "a → b … c ± d", render("a → b ... c +- d\n")
  end

  def test_a_literal_character_without_a_glyph_is_replaced_with_a_warning
    text = nil
    _, err = capture_io { text = render("Text 日本 and ≤ here.\n") }
    assert_equal "Text ?? and ? here.", text
    assert_includes err, "U+65E5"
    assert_includes err, "U+2264"
  end

  def test_code_and_strong_runs_are_checked_against_their_own_font
    text = nil
    capture_io { text = render("*x <= 1* and `日`\n\n```\n日 <= ≤\n```\n") }
    assert_equal "x <= 1 and ?? <= ?", text
  end

  def test_a_font_that_has_the_glyph_draws_it
    skip "HexaPDF ships no Inter font" unless File.file?(INTER)

    assert_equal "Use x ≤ 10 here.", render("Use x <= 10 here.\n", base_font: INTER)
  end

  def test_a_configured_fallback_font_still_supplies_a_missing_glyph
    composer = HexaPDF::Composer.new
    composer.document.config["font.fallback"] = ["Symbol"]
    Carve::Hexapdf::Renderer.new(composer).render_document(
      Carve.parse("Angle α here.\n")
    )
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.pdf")
      composer.write(path)
      assert_equal "Angle α here.", page_text(path)
    end
  end
end
