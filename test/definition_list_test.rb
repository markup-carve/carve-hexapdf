# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

# Asserts on drawn text: a valid PDF alone passed while every term and
# description was dropped.
class DefinitionListTest < Minitest::Test
  def drawn(source)
    pdf = Carve::Hexapdf.render(source)
    HexaPDF::Document.new(io: StringIO.new(pdf)).pages.map { |page| page.contents.to_s }.join
  end

  def test_terms_and_descriptions_are_drawn_in_order
    content = drawn(":: Alpha\n: First body.\n\n:: Beta\n: Second body.\n")

    words = %w[Alpha First Beta Second]
    words.each { |word| assert_includes content, word }
    assert_equal words, words.sort_by { |word| content.index(word) }
  end

  def test_description_block_content_is_drawn
    content = drawn(":: Term\n: Opening line.\n\n  - Nested item\n\n  Closing paragraph.\n")

    %w[Term Opening Nested Closing].each { |word| assert_includes content, word }
  end

  def test_term_is_bold
    pdf = Carve::Hexapdf.render(":: Term\n: Body.\n")
    fonts = HexaPDF::Document.new(io: StringIO.new(pdf)).pages.flat_map do |page|
      page_fonts = page.resources[:Font]
      page_fonts.each.map { |_name, font| font[:BaseFont].to_s }
    end

    assert_includes fonts, "Times-Bold"
  end
end
