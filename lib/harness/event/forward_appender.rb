module Harness
  module Event
    class ForwardAppender
      class InvalidEvent < StandardError
        attr_reader :errors
        def initialize(errors)
          @errors = Array(errors)
          super("invalid event: " + @errors.join("; "))
        end
      end

      def self.append(**kwargs)
        new(**kwargs).append
      end

      def initialize(game_time:, scope:, location: nil, details: {}, participants: [], references_event_id: nil)
        @game_time           = game_time
        @scope               = scope
        @location            = location
        @details             = details
        @participants        = participants
        @references_event_id = references_event_id
        @errors              = []
      end

      def append
        validate!
        raise InvalidEvent, @errors if @errors.any?

        loc, details = resolve_location

        ::ActiveRecord::Base.transaction do
          event = ::Event.create!(
            game_time:           @game_time,
            location:            loc,
            scope:               @scope,
            details:             details,
            references_event_id: @references_event_id
          )
          @participants.each do |p|
            ::EventParticipant.create!(
              event:       event,
              character:   p[:character],
              role:        p.fetch(:role)
            )
          end
          event
        end
      end

      private

      def validate!
        unless ::Event::ALLOWED_SCOPES.include?(@scope)
          @errors << "scope=#{@scope.inspect} must be one of #{::Event::ALLOWED_SCOPES.inspect}"
        end

        unless @game_time.is_a?(Integer)
          @errors << "game_time must be an integer (got #{@game_time.inspect})"
        end

        unless @location.is_a?(::Location) || @location.is_a?(String) || @location.nil?
          @errors << "location must be a Location, a String name, or nil (got #{@location.class})"
        end

        @participants.each_with_index do |p, i|
          # Post-Phase-2: every participant is a class-4 Character row.
          # Class-2 (actor_name string) participants are retired —
          # callers must Hatchery their named participants up front.
          if p[:character].blank?
            @errors << "participant[#{i}] must have a :character (post-Phase-2: class-2 actor_name strings retired)"
          end
          @errors << "participant[#{i}] missing :role" if p[:role].to_s.strip.empty?
        end
      end

      # Returns [Location_or_nil, details_hash]. A String location resolves to
      # an existing row by name when one is found; otherwise the name is kept
      # as prose in details["location_name"] and location_id stays nil. This
      # is the location-side equivalent of class-2 actor_name participants —
      # named-but-unmaterialized places live as prose until narrative gravity
      # demands a row (player wants to go there, character claims to be from
      # there in a scene the player visits). Auto-stubs were retired.
      def resolve_location
        details = stringify_details(@details)
        case @location
        when ::Location
          [ @location, details ]
        when String
          if (existing = ::Location.find_by(name: @location))
            [ existing, details ]
          else
            [ nil, details.merge("location_name" => @location) ]
          end
        when nil
          [ nil, details ]
        end
      end

      def stringify_details(details)
        return {} if details.nil?
        details.respond_to?(:deep_stringify_keys) ? details.deep_stringify_keys : details.to_h.transform_keys(&:to_s)
      end
    end
  end
end
