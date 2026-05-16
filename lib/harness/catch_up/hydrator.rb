require "json"
require "set"

module Harness
  module CatchUp
    # Parses catch-up generator output into a list of event payloads.
    # Differs from Genesis::Hydrator only in its game_time window check:
    # events must satisfy floor_game_time < gt < current_game_time (strictly
    # within the gap), and only "local" scope is permitted (regional+ comes
    # from the spine sim, not from catch-up).
    class Hydrator
      class InvalidOutput < StandardError
        attr_reader :errors
        def initialize(errors)
          @errors = Array(errors)
          super("invalid catch-up output:\n  - #{@errors.join("\n  - ")}")
        end
      end

      ALLOWED_SCOPES = %w[local].freeze
      MAX_EVENTS     = 5

      def self.hydrate(llm_output:, current_game_time:, floor_game_time:, allowed_names: nil)
        new(llm_output, current_game_time, floor_game_time, allowed_names).hydrate
      end

      def initialize(llm_output, current_game_time, floor_game_time, allowed_names = nil)
        @llm = if llm_output.is_a?(String)
          begin
            Harness::LLM::JsonResponse.parse(llm_output)
          rescue JSON::ParserError => e
            raise InvalidOutput, [ "output is not valid JSON: #{e.message}" ]
          end
        else
          llm_output
        end
        @current_game_time = current_game_time
        @floor_game_time   = floor_game_time
        @allowed_set       = (allowed_names || []).map(&:to_s).to_set
        @errors            = []
      end

      def hydrate
        validate_top_level
        raise_if_errors

        events = validate_events
        raise_if_errors

        events
      end

      private

      def validate_top_level
        unless @llm.is_a?(Hash)
          @errors << "top-level output must be a JSON object"
          return
        end
        unless @llm["events"].is_a?(Array)
          @errors << "\"events\" must be an array (empty is allowed)"
        end
      end

      def validate_events
        out = []
        events = Array(@llm["events"])
        if events.size > MAX_EVENTS
          @errors << "events.size=#{events.size} exceeds MAX_EVENTS=#{MAX_EVENTS}"
          return out
        end

        events.each_with_index do |e, i|
          prefix = "events[#{i}]"
          unless e.is_a?(Hash)
            @errors << "#{prefix} is not an object"
            next
          end

          gt = e["game_time"]
          unless gt.is_a?(Integer)
            @errors << "#{prefix}: game_time must be an integer"
            next
          end
          if gt <= @floor_game_time
            @errors << "#{prefix}: game_time=#{gt} must be strictly greater than floor_game_time=#{@floor_game_time}"
            next
          end
          if gt >= @current_game_time
            @errors << "#{prefix}: game_time=#{gt} must be strictly less than current_game_time=#{@current_game_time}"
            next
          end

          scope = e["scope"]
          unless ALLOWED_SCOPES.include?(scope)
            @errors << "#{prefix}: scope=#{scope.inspect} must be one of #{ALLOWED_SCOPES.inspect}"
            next
          end

          details = e["details"]
          unless details.is_a?(Hash)
            @errors << "#{prefix}: details must be an object"
            next
          end

          participants = validate_participants(e["participants"], prefix)
          next if participants.nil?

          out << {
            "game_time"    => gt,
            "scope"        => scope,
            "details"      => details,
            "participants" => participants
          }
        end
        out
      end

      def validate_participants(raw, prefix)
        list = Array(raw)
        out  = []
        list.each_with_index do |p, j|
          sub = "#{prefix}.participants[#{j}]"
          unless p.is_a?(Hash)
            @errors << "#{sub} is not an object"
            return nil
          end
          name = p["actor_name"]
          role = p["role"]
          unless name.is_a?(String) && !name.strip.empty?
            @errors << "#{sub}: actor_name must be a non-empty string"
            return nil
          end
          unless role.is_a?(String) && !role.strip.empty?
            @errors << "#{sub}: role must be a non-empty string"
            return nil
          end
          stripped = name.strip
          unless @allowed_set.include?(stripped)
            @errors << "#{sub}: actor_name=#{stripped.inspect} is not one of the existing characters at this location. Catch-up may only reference characters who live here — it does NOT spawn new rows. Either pick a name from the allowed set or omit this event."
            return nil
          end
          out << { "actor_name" => stripped, "role" => role.strip }
        end
        out
      end

      def raise_if_errors
        raise InvalidOutput, @errors if @errors.any?
      end
    end
  end
end
