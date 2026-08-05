# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

# U+E000 never reaches the page (carve-hexapdf#14).
#
# The engines publish U+E000 in a text value to STAND FOR a no-break space the
# parser resolved - from an escaped space (`a\ b`) or from a line block's
# preserved indentation (PART 9 section 23). PART 12 is explicit: a consumer maps
# it to its target's no-break space, or to an ordinary space where the target has
# none, and MUST NOT emit it.
#
# A PDF has one, so it maps to U+00A0.
#
# Emitting the sentinel was not merely wrong. The default Type1 font has no glyph
# for a private-use codepoint, so rendering `a\ b` raised
# HexaPDF::MissingGlyphError and produced no document at all - the whole render
# failed on an ordinary escaped space.
class ResolvedNbspTest < Minitest::Test
  SENTINEL = "\u{E000}"
  NBSP = "\u{00A0}"

  def doc(*children)
    { type: "document", children: children }
  end

  def para(*inlines)
    { type: "paragraph", children: inlines }
  end

  def stream(bytes)
    HexaPDF::Document.new(io: StringIO.new(bytes)).pages.map(&:contents).join("\n")
  end

  # The sentinel must produce exactly what an authored no-break space produces.
  # Comparing the CONTENT STREAM rather than the file: a PDF carries a timestamp
  # and a document id, so two renders of the same page never match byte for byte.
  def assert_same_as_nbsp(build)
    sentinel = stream(Carve::Hexapdf.render_ast(build.call(SENTINEL)))
    authored = stream(Carve::Hexapdf.render_ast(build.call(NBSP)))
    assert_equal authored, sentinel, "the sentinel did not render as a no-break space"
    refute_includes sentinel, SENTINEL, "the sentinel reached the content stream"
  end

  def test_a_text_value_maps_the_sentinel
    assert_same_as_nbsp(->(c) { doc(para({ type: "text", value: "a#{c}b" })) })
  end

  def test_an_inline_code_value_maps_the_sentinel
    # Verbatim content is not an exception: PART 12 says a consumer must not emit
    # the sentinel, and the character it stands for is what the author wrote.
    assert_same_as_nbsp(->(c) { doc(para({ type: "code", value: "a#{c}b" })) })
  end

  def test_a_code_block_maps_the_sentinel
    assert_same_as_nbsp(->(c) { doc({ type: "code_block", content: "a#{c}b", lang: "" }) })
  end

  def test_an_image_alt_maps_the_sentinel
    # The alt is drawn as italic text when the image itself cannot be loaded,
    # which is the path a missing `src` takes.
    assert_same_as_nbsp(lambda { |c|
      doc({ type: "image", src: "/nope-does-not-exist.png", alt: "a#{c}b" })
    })
  end

  def test_the_render_no_longer_raises
    # The regression in its plainest form. Before the mapping this raised
    # HexaPDF::MissingGlyphError and no PDF came back at all.
    bytes = Carve::Hexapdf.render_ast(doc(para({ type: "text", value: "a#{SENTINEL}b" })))
    assert_equal "%PDF", bytes[0, 4]
  end

  def test_text_without_the_sentinel_is_untouched
    # The control. The mapping must not disturb ordinary content.
    plain = stream(Carve::Hexapdf.render_ast(doc(para({ type: "text", value: "a b" }))))
    again = stream(Carve::Hexapdf.render_ast(doc(para({ type: "text", value: "a b" }))))
    assert_equal again, plain
    refute_includes plain, SENTINEL
  end
end
