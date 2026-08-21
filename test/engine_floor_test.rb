# frozen_string_literal: true

# WHETHER THE ENGINE THIS GEM RESOLVES IS ONE THE FLOOR ACTUALLY ADMITS.
#
# `carve-hexapdf.gemspec` declares a RANGE, so what a consumer installs is
# whatever RubyGems serves inside it. Nothing else in this suite notices which
# engine that turned out to be: measured on 2026-08-21, all 82 existing runs
# pass against carve-lang 0.1.0 - the engine the floor EXCLUDES - exactly as
# well as against 0.1.1, because most of them hand `render_ast` a Hash built in
# the test rather than one the engine produced.
#
# The engine still decides what the PDFs look like. `examples/01-spec.crv`
# renders to 3268 bytes on 0.1.1 and 3341 on 0.1.0, and neither number is
# recorded anywhere. So the suite is not blind to the engine because the engine
# does not matter; it is blind because nothing asks.
#
# WHAT THE FLOOR CLAIMS HERE. Not what the sibling HTML plugins claim. Their
# floor is about a list-valued URL attribute rendered unsanitized, which is a
# defect in the engine's HTML renderer - this gem consumes the AST, and the AST
# carries a raw `javascript:` href in 0.1.0 and 0.1.1 alike. What 0.1.1 gives
# THIS renderer is the post-rename node vocabulary its primary arms are written
# for. Measured through `Carve.parse` against both:
#
#   source            carve-lang 0.1.1   carve-lang 0.1.0
#   -----------------------------------------------------------------
#   *x*               strong             emphasis (carrying kind:)
#   [^n]              footnote_ref       footnote
#   ![a](x.png)       block image        block_image
#
# `renderer.rb` keeps a compatibility arm for each old name, so an older engine
# does not raise - it renders, and what is wrong about the page is that a rename
# nobody here made changed it. That is the failure mode of #10, and it is why
# this file asserts the vocabulary rather than merely rendering and checking for
# an exception.

require "minitest/autorun"
require "carve/hexapdf"

class EngineFloorTest < Minitest::Test
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
    define_method(:"test_engine_publishes_#{want}") do
      got = node_types(Carve.parse(source))
      assert_includes got, want,
                      "the resolved carve-lang (#{Carve::VERSION}) publishes no #{want.inspect} " \
                      "node for #{source.inspect}; it published #{got.uniq.inspect}. The floor " \
                      "in carve-hexapdf.gemspec is the claim that it does."
    end
  end

  # THE DISCRIMINATOR. Every assertion above would hold over an engine whose
  # output this renderer could no longer draw, and the file would report a
  # healthy floor while every PDF came out empty. This is what makes the three
  # above evidence rather than a shape check.
  def test_a_document_still_reaches_a_page_through_the_resolved_engine
    pdf = Carve::Hexapdf.render(<<~CARVE)
      # Heading

      A *bold* word, a /slanted/ one, and a note[^n].

      [^n]: the note
    CARVE

    assert pdf.start_with?("%PDF-"), "the render is not a PDF: #{pdf[0, 16].inspect}"
    assert_operator pdf.bytesize, :>, 512, "the render is too small to hold the document"
  end
end
