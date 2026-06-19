module Harness
  module Worldgen
    # Render a Map as ASCII for inspection. Two-layer:
    #   - background: biome at each cell ('.' lowland, '^' highland)
    #     ONLY drawn when map.seed is present (we need the noise field).
    #   - foreground: city marker (kingdom_id digit; letter if > 9 kingdoms)
    #
    # Default rendering is 60 columns wide; rows scale to keep aspect ratio.
    # Cells are sampled by mapping (col, row) → (x, y) on the noise field.
    module Ascii
      DEFAULT_WIDTH = 60

      def self.render(map, width: DEFAULT_WIDTH)
        grid = map.seed ? build_grid_with_biomes(map, width) : build_grid_blank(map, width)
        place_cities!(grid, map, width)
        legend = build_legend(map)
        ([ horizontal_rule(width) ] + grid.map(&:join) + [ horizontal_rule(width) ] + legend).join("\n")
      end

      def self.build_grid_with_biomes(map, width)
        noise  = Noise.new(seed: map.seed)
        scale  = map.size.to_f / width
        height = (map.size.to_f / scale / 2).round  # halve rows — chars are ~2x taller than wide
        Array.new(height) do |row|
          Array.new(width) do |col|
            x = col * scale
            y = row * scale * 2
            Biome.at(noise: noise, x: x, y: y) == Biome::HIGHLAND ? "^" : "."
          end
        end
      end

      def self.build_grid_blank(map, width)
        scale  = map.size.to_f / width
        height = (map.size.to_f / scale / 2).round
        Array.new(height) { Array.new(width, ".") }
      end

      def self.place_cities!(grid, map, width)
        height = grid.size
        scale  = map.size.to_f / width
        map.cities.each do |c|
          col = (c.x / scale).round.clamp(0, width - 1)
          row = (c.y / (scale * 2)).round.clamp(0, height - 1)
          grid[row][col] = kingdom_marker(c.kingdom_id)
        end
      end

      def self.kingdom_marker(id)
        # Player-created wilderness (wilderness_leaf) is a top-level coordinated
        # location with no kingdom — it lands here with a nil id. Mark it as
        # uncharted rather than crashing on the comparison.
        return "*" if id.nil?
        return id.to_s if id < 10
        ("A".ord + (id - 10)).chr
      end

      def self.build_legend(map)
        lines = []
        lines << "kingdoms (#{map.kingdoms.size}):"
        map.kingdoms.each do |k|
          anchor = map.cities[k.anchor_city_id]
          members = map.cities.count { |c| c.kingdom_id == k.id }
          name = k.name || "(unnamed)"
          lines << "  [#{kingdom_marker(k.id)}] #{name}  members=#{members}  anchor=city##{anchor.id} at (#{'%.1f' % anchor.x}, #{'%.1f' % anchor.y})"
        end
        lines << ""
        lines << "cities (#{map.cities.size}):"
        map.cities.each do |c|
          name = c.name || "(unnamed)"
          lines << "  city##{c.id} [#{kingdom_marker(c.kingdom_id)}] #{name}  (#{'%.1f' % c.x}, #{'%.1f' % c.y})  #{c.biome}"
        end
        lines
      end

      def self.horizontal_rule(width)
        "+" + "-" * width + "+"
      end
    end
  end
end
