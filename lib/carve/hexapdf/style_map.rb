# frozen_string_literal: true

module Carve
  module Hexapdf
    # Hierarchical style resolver for renderer properties.
    class StyleMap
      def self.deep_freeze(value)
        case value
        when Hash
          value.each_value { |entry| deep_freeze(entry) }
        when Array
          value.each { |entry| deep_freeze(entry) }
        end
        value.freeze
      end
      private_class_method :deep_freeze

      DEFAULTS = deep_freeze({
        "base" => { font: "Times" },
        "heading" => { margin: [10, 0, 6] },
        "heading.1" => { font_size: 22 },
        "heading.2" => { font_size: 18 },
        "heading.3" => { font_size: 15 },
        "heading.4" => { font_size: 13 },
        "heading.5" => { font_size: 12 },
        "heading.6" => { font_size: 11 },
        "paragraph" => { margin: [0, 0, 8] },
        "code" => { font: "Courier" },
        "code.block" => {
          font_size: 9,
          margin: [2, 0, 8],
          box: { background_color: "f2f2f2", padding: 6 },
        },
        "code.inline" => {},
        "quote" => {
          box: { margin: [2, 0, 8], padding: [4, 10], background_color: "f7f7f7" },
        },
        "admonition" => {
          box: { margin: [2, 0, 8], padding: [6, 10], background_color: "eef3fb" },
          title_margin: [0, 0, 4],
        },
        "list" => { item_spacing: 3, content_indentation: 18 },
        "definition_list" => { box: { margin: [0, 0, 8] }, definition_indent: 16 },
        "table" => { font_size: 10, cell_padding: 4, margin: [2, 0, 8] },
        "table.header" => {},
        "table.caption" => { font_size: 9, margin: [0, 0, 8] },
        "figure.caption" => { font_size: 9, margin: [2, 0, 8], text_align: :center },
        "link" => { fill_color: "hp-blue" },
        "highlight" => { background_color: "fff3a3" },
        "image" => { margin: [2, 0, 8] },
        "math" => { font_size: 11, margin: [4, 0, 8], box: { padding: 4 } },
        "thematic_break" => { height: 2, margin: [8, 0, 8], background_color: "cccccc" },
      })

      def initialize(styles = nil)
        @user = normalize(styles || {})
        @memo = {}
      end

      def resolve(key)
        normalized = normalize_key(key)
        validate_key!(normalized)
        @memo[normalized] ||= chain_for(normalized).each_with_object({}) do |part, resolved|
          merge_entry!(resolved, DEFAULTS[part]) if DEFAULTS.key?(part)
          merge_entry!(resolved, @user[part]) if @user.key?(part)
        end.freeze
      end

      def user_set?(key, property = nil)
        normalized = normalize_key(key)
        return false unless @user.key?(normalized)
        return true if property.nil?

        @user[normalized].key?(property)
      end

      def user_set_in_chain?(key, property)
        chain_for(normalize_key(key)).any? { |part| user_set?(part, property) }
      end

      private

      def normalize(styles)
        unless styles.respond_to?(:each_pair)
          raise ArgumentError, "styles must be a Hash-like object"
        end

        styles.each_pair.with_object({}) do |(key, value), out|
          normalized = normalize_key(key)
          validate_key!(normalized)
          out[normalized] = normalize_entry(value, normalized)
        end
      end

      def normalize_key(key)
        key.to_s
      end

      def normalize_entry(value, key)
        unless value.respond_to?(:each_pair)
          raise ArgumentError, "style entry #{key.inspect} must be a Hash-like object"
        end

        value.each_pair.with_object({}) do |(property, property_value), out|
          out[property.to_sym] = property_value.is_a?(Hash) ? normalize_property_hash(property_value) : property_value
        end
      end

      def normalize_property_hash(hash)
        hash.each_pair.with_object({}) { |(key, value), out| out[key.to_sym] = value }
      end

      def validate_key!(key)
        return if DEFAULTS.key?(key)
        return if key.match?(/\Aheading\.\d+\z/)
        # Admonition kinds are an open vocabulary (any word the parser accepts,
        # including hyphenated ones), so accept any dot-free suffix.
        return if key.match?(/\Aadmonition\.[^\s.]+\z/)

        raise ArgumentError, "unknown style key: #{key.inspect}"
      end

      def chain_for(key)
        chain = []
        current = key
        loop do
          chain << current
          break if current == "base"

          current = current.include?(".") ? current.rpartition(".").first : "base"
        end
        chain.reverse
      end

      def merge_entry!(target, source)
        return unless source

        source.each_pair do |key, value|
          target[key] = if key == :box && value.is_a?(Hash)
                          (target[key] || {}).merge(value)
                        else
                          value
                        end
        end
      end
    end
  end
end
