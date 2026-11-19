# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

# Shapes that are new in the Carve 0.2 tree, rendered from source through the
# pinned engine.
class TreeV2Test < Minitest::Test
  def strings(source)
    bytes = Carve::Hexapdf.render(source)
    HexaPDF::Document.new(io: StringIO.new(bytes)).pages.map(&:contents).join
                     .scan(/\((?:[^()\\]|\\.)*\)/).map { |s| s[1..-2].gsub(/\\(.)/, '\1') }
  end

  def test_a_captioned_code_block_draws_its_caption_after_the_code
    out = strings("```ruby\nputs 1\n```\n^ Listing #: Output\n")
    assert_operator out.index { |s| s.include?("puts 1") }, :<, out.index { |s| s.include?("Output") }
  end

  def test_a_div_draws_its_quoted_title_before_its_body
    out = strings("::: aside \"Side note\"\nBody text.\n:::\n")
    assert_equal ["Side note", "Body text."], out.select { |s| ["Side note", "Body text."].include?(s) }
  end

  def test_an_ordered_list_starts_at_its_marker_number
    out = strings("3. three\n4. four\n")
    assert_includes out, "3."
  end

  def test_a_resolved_cross_reference_draws_its_key
    out = strings("{#plan}\n= Plan\n\nSee </#plan>.\n")
    assert_includes out, "plan"
  end

  def test_a_0_1_tree_from_the_engine_is_refused_with_a_clear_error
    error = assert_raises(Carve::Hexapdf::EngineError) do
      Carve::Hexapdf.send(:require_tree_v2, { type: "document", children: [] })
    end
    assert_match(/Carve 0.2 engine/, error.message)
    assert_equal "2.0", Carve::Hexapdf.send(:require_tree_v2, Carve.parse("x"))[:astVersion]
  end
end
