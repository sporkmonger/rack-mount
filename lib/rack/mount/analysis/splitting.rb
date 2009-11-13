require 'rack/mount/utils'

module Rack::Mount
  module Analysis
    module Splitting
      NULL = "\0".freeze

      class Key < Array
        def initialize(method, index, separators)
          replace([method, index, separators])
        end

        def self.split(value, separator_pattern)
          keys = value.split(separator_pattern)
          keys.shift if keys[0] == ''
          keys << NULL
          keys
        end

        def call(cache, obj)
          (cache[self[0]] ||= self.class.split(obj.send(self[0]), self[2]))[self[1]]
        end

        def call_source(cache, obj)
          "(#{cache}[:#{self[0]}] ||= Analysis::Splitting::Key.split(#{obj}.#{self[0]}, #{self[2].inspect}))[#{self[1]}]"
        end
      end

      def clear
        @boundaries = {}
        super
      end

      def <<(key)
        super
        key.each_pair do |k, v|
          analyze_capture_boundaries(v, @boundaries[k] ||= Histogram.new)
        end
      end

      def separators(key)
        @boundaries[key].select_upper
      end

      def process_key(requirements, method, requirement)
        separators = separators(method)
        if requirement.is_a?(Regexp) && separators.any?
          generate_split_keys(requirement, separators).each_with_index do |value, index|
            requirements[Key.new(method, index, Regexp.union(*separators))] = value
          end
        else
          super
        end
      end

      private
        def analyze_capture_boundaries(regexp, boundaries) #:nodoc:
          return boundaries unless regexp.is_a?(Regexp)

          parts = Utils.parse_regexp(regexp)
          parts.each_with_index do |part, index|
            if part.is_a?(Reginald::Group)
              if index > 0
                previous = parts[index-1]
                if previous.is_a?(Reginald::Character)
                  boundaries << previous.to_str
                end
              end

              if inside = part[0][0]
                if inside.is_a?(Reginald::Character)
                  boundaries << inside.to_str
                end
              end

              if index < parts.length
                following = parts[index+1]
                if following.is_a?(Reginald::Character)
                  boundaries << following.to_str
                end
              end
            end
          end

          boundaries
        end

        def generate_split_keys(regexp, separators) #:nodoc:
          segments = []
          buf = nil
          casefold = regexp.casefold?
          parts = Utils.parse_regexp(regexp)
          parts.each_with_index do |part, index|
            case part
            when Reginald::Anchor
              if part.value == '$' || part.value == '\Z'
                segments << join_buffer(buf, regexp) if buf
                segments << NULL
                buf = nil
                break
              end
            when Reginald::Character
              if separators.any? { |s| part.include?(s) }
                segments << join_buffer(buf, regexp) if buf
                peek = parts[index+1]
                if peek.is_a?(Reginald::Character) && separators.include?(peek)
                  segments << ''
                end
                buf = nil
              else
                buf ||= Reginald::Expression.new([])
                buf << part
              end
            when Reginald::Group
              if part.quantifier == '?'
                value = part.expression.first
                if separators.any? { |s| value.include?(s) }
                  segments << join_buffer(buf, regexp) if buf
                  buf = nil
                end
                break
              elsif part.quantifier == nil
                break if separators.any? { |s| part.include?(s) }
                buf = nil
                segments << part.to_regexp
              else
                break
              end
            when Reginald::CharacterClass
              break if separators.any? { |s| part.include?(s) }
              buf = nil
              segments << part.to_regexp
            else
              break
            end

            if index + 1 == parts.size
              segments << join_buffer(buf, regexp) if buf
              buf = nil
              break
            end
          end

          while segments.length > 0 && (segments.last.nil? || segments.last == '')
            segments.pop
          end

          segments.shift if segments[0].nil? || segments[0] == ''

          segments
        end

        def join_buffer(parts, regexp)
          if parts.literal? && !regexp.casefold?
            parts.to_s
          else
            parts.to_regexp
          end
        end
    end
  end
end
