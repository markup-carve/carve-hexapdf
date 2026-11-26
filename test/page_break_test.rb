# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

# `{.page-break}` on `***` is the page-break convention (carve#6793): a
# thematic break with the class `page-break` starts a new page and draws no bar.
class PageBreakTest < Minitest::Test
  def doc(*children)
    { type: "document", children: children }
  end

  def para(value)
    { type: "paragraph", children: [{ type: "text", value: value }] }
  end

  def page_break
    { type: "thematic_break", attrs: { classes: ["page-break"] } }
  end

  def pages(bytes)
    HexaPDF::Document.new(io: StringIO.new(bytes)).pages.map do |page|
      page.contents.scan(/\((?:[^()\\]|\\.)*\)/).map { |s| s[1..-2] }.join(" ")
    end
  end

  def bar_count(bytes)
    HexaPDF::Document.new(io: StringIO.new(bytes)).pages.sum { |page| page.contents.scan(/\bre\b/).size }
  end

  def test_a_page_break_starts_a_new_page
    out = pages(Carve::Hexapdf.render_ast(doc(para("One"), page_break, para("Two"))))
    assert_equal 2, out.size
    assert_includes out[0], "One"
    assert_includes out[1], "Two"
  end

  def test_a_page_break_draws_no_bar
    plain = Carve::Hexapdf.render_ast(doc(para("One"), { type: "thematic_break" }, para("Two")))
    broken = Carve::Hexapdf.render_ast(doc(para("One"), page_break, para("Two")))
    assert_equal 1, pages(plain).size
    assert_operator bar_count(plain), :>, bar_count(broken)
  end

  def test_a_page_break_on_an_empty_page_adds_no_blank_page
    assert_equal 1, pages(Carve::Hexapdf.render_ast(doc(page_break, para("Only")))).size
  end

  def test_a_page_break_after_a_float_still_breaks
    image = { type: "image", src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAADElEQVR4nGNgIB0AAAA0AAF2Xq7DAAAAAElFTkSuQmCC", alt: "Floated" }
    bytes = Carve::Hexapdf.render_ast(doc(image, page_break, para("Two")),
                                      styles: { image: { position: :float, width: 40 } })
    assert_equal 2, pages(bytes).size
  end

  def test_a_page_break_after_an_unmasked_paragraph_still_breaks
    bytes = Carve::Hexapdf.render_ast(doc(para("One"), page_break, para("Two")),
                                      styles: { paragraph: { mask_mode: :none } })
    assert_equal 2, pages(bytes).size
  end

  def test_a_page_break_inside_a_container_draws_nothing
    quote = { type: "block_quote", children: [para("In"), page_break, para("Out")] }
    out = pages(Carve::Hexapdf.render_ast(doc(quote)))
    assert_equal 1, out.size
    assert_includes out[0], "In"
    assert_includes out[0], "Out"
  end

  def test_the_convention_parsed_from_source_breaks_the_page
    out = pages(Carve::Hexapdf.render("One\n\n{.page-break}\n***\n\nTwo\n"))
    assert_equal 2, out.size
    assert_includes out[1], "Two"
  end
end
