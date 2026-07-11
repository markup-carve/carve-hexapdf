# frozen_string_literal: true

require "minitest/autorun"
require "carve/hexapdf/style_map"

class StyleMapTest < Minitest::Test
  def test_specificity_prefers_default_child_over_user_parent
    styles = Carve::Hexapdf::StyleMap.new("heading" => { font_size: 30, fill_color: "333333" })

    assert_equal 22, styles.resolve("heading.1")[:font_size]
    assert_equal "333333", styles.resolve("heading.1")[:fill_color]
  end

  def test_user_overrides_default_at_same_key
    styles = Carve::Hexapdf::StyleMap.new("heading.1" => { font_size: 30 })

    assert_equal 30, styles.resolve("heading.1")[:font_size]
  end

  def test_deep_merges_box_and_replaces_arrays_atomically
    styles = Carve::Hexapdf::StyleMap.new(
      "code.block" => {
        margin: [9, 8, 7],
        box: { padding: 12 },
      },
    )

    resolved = styles.resolve("code.block")
    assert_equal [9, 8, 7], resolved[:margin]
    assert_equal "f2f2f2", resolved[:box][:background_color]
    assert_equal 12, resolved[:box][:padding]
  end

  def test_symbol_and_string_keys_normalize
    styles = Carve::Hexapdf::StyleMap.new(:"heading.1" => { fill_color: "111111" })

    assert_equal "111111", styles.resolve("heading.1")[:fill_color]
  end

  def test_lenient_admonition_kind_and_heading_level
    styles = Carve::Hexapdf::StyleMap.new(
      "admonition.custom_kind" => { box: { background_color: "ffeecc" } },
    )

    assert_equal [10, 0, 6], styles.resolve("heading.7")[:margin]
    assert_equal "ffeecc", styles.resolve("admonition.custom_kind")[:box][:background_color]
  end

  def test_unknown_key_raises
    assert_raises(ArgumentError) do
      Carve::Hexapdf::StyleMap.new("code.blck" => {})
    end
  end

  def test_hyphenated_admonition_kind_accepted
    styles = Carve::Hexapdf::StyleMap.new(
      "admonition.my-note" => { box: { background_color: "ffeecc" } },
    )

    assert_equal "ffeecc", styles.resolve("admonition.my-note")[:box][:background_color]
    assert_equal [2, 0, 8], styles.resolve("admonition.my-note")[:box][:margin]
  end
end
