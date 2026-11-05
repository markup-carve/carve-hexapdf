# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

# Engine readings that landed after carve-lang 0.1.13, as they reach the page.
class EngineNextTest < Minitest::Test
  class Positions < HexaPDF::Content::Processor
    attr_reader :at

    def initialize
      super
      @at = {}
    end

    def show_text(str)
      boxes = decode_text_with_positioning(str)
      @at[boxes.string] ||= boxes.lower_left
    end
    alias show_text_with_positioning show_text
  end

  def drawn(source)
    processor = Positions.new
    pdf = Carve::Hexapdf.render(source)
    HexaPDF::Document.new(io: StringIO.new(pdf)).pages.each { |page| page.process_contents(processor) }
    processor.at
  end

  def text(source)
    drawn(source).keys.join(" ")
  end

  # carve#5091 D3: alignment sits in the cell's leading braces.
  def test_braced_header_alignment_aligns_its_column
    at = drawn("|={>} Long header text |\n| 5 |\n")

    assert_operator at["5"][0], :>, at["Long header text"][0]
    refute_includes text("|={>} Long header text |\n| 5 |\n"), "{>}"
  end

  def test_braced_body_alignment_stays_local
    at = drawn("|= Long header text |\n|{>} 5 |\n| 6 |\n")

    assert_operator at["5"][0], :>, at["6"][0]
  end

  # A lone `---` on the first line opens frontmatter that runs to the end.
  def test_unclosed_first_line_frontmatter_draws_nothing
    content = text("---\ntitle: Hidden\n\n# Heading\n")

    refute_includes content, "Hidden"
    refute_includes content, "Heading"
  end

  # carve#5012: an erased `%%` line folds the paragraph across it.
  def test_erased_comment_line_folds_the_paragraph
    at = drawn("alpha\n%% hidden\nbeta\n")

    assert_equal at.keys.find { |k| k.include?("alpha") }, at.keys.find { |k| k.include?("beta") }
    refute_includes at.keys.join, "hidden"
  end

  # carve#5167: a comment between a term and its description is the
  # description's first block, so the description stays one.
  def test_comment_between_term_and_description
    content = text(":: Term\n%% note\n: Desc\n")

    assert_includes content, "Desc"
    refute_includes content, ": Desc"
    refute_includes content, "note"
  end
end
