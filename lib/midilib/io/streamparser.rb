require_relative '../consts'
require_relative '../event'

module MIDI
  module IO
    # Parses a raw stream of MIDI 1.0 bytes arriving in arbitrary chunks,
    # such as the blocks delivered by a MIDI device. Unlike MIDIFile, there
    # is no +MThd+ header and no delta times; every complete message is
    # turned into an Event object (with delta_time 0) and returned as soon
    # as it is complete. The caller is responsible for stamping each event
    # with the time it was received.
    #
    #   parser = MIDI::IO::StreamParser.new
    #   events = parser.feed(bytes)   # bytes may be an Array or a String
    #   events += parser.finish       # flush and validate at end of stream
    #
    # Bytes may be split across calls at any point. Channel voice running
    # status is remembered across chunks. System common messages clear
    # running status, but system realtime single-byte messages never do;
    # they are emitted immediately even when they appear between the data
    # bytes of another message or inside a system exclusive dump, leaving
    # the interrupted message intact.
    class StreamParser
      # Number of data bytes for each channel voice status high nibble
      # (0x8 through 0xE). 0xF entries are system messages, handled below.
      CHANNEL_DATA_BYTES = [0, 0, 0, 0, 0, 0, 0, 0,
                            2, 2, 2, 2, 1, 1, 2, 0].freeze

      # Default maximum number of payload bytes accumulated for one
      # system exclusive message (one mebibyte).
      DEFAULT_MAX_SYSEX_BYTES = 1 << 20

      class Error < StandardError; end

      # Maximum number of payload bytes that may be accumulated for a
      # single system exclusive message.
      attr_reader :max_sysex_bytes

      # Returns true while a system exclusive message is being assembled.
      def sysex_active?
        !@sysex_data.nil?
      end

      # Create a new parser. +max_sysex_bytes+ is the maximum number of
      # payload bytes (not counting the leading 0xF0 and trailing 0xF7)
      # that may be accumulated for one system exclusive message.
      def initialize(max_sysex_bytes: DEFAULT_MAX_SYSEX_BYTES)
        @max_sysex_bytes = max_sysex_bytes
        reset
      end

      # Feed one chunk of raw MIDI bytes, given as an Array of integers or
      # as a String. Returns an Array of Events completed by this chunk.
      # Raises StreamParser::Error on malformed input, including data bytes
      # without a status byte, undefined system common status bytes, or a
      # system exclusive message that exceeds +max_sysex_bytes+.
      def feed(bytes)
        bytes = bytes.bytes if bytes.is_a?(String)
        events = []
        bytes.each { |byte| process_byte(byte, events) }
        events
      end

      # Signal the end of the byte stream and return any buffered events.
      # Raises StreamParser::Error if a channel voice or system common
      # message or a system exclusive dump is left incomplete, so that
      # truncated messages are never silently discarded.
      def finish
        if @sysex_data
          raise Error, "unterminated system exclusive message: " \
                       "#{@sysex_data.length} byte(s) without 0xF7"
        end
        if @pending_status
          raise Error, "incomplete message: status 0x#{('%02x' % @pending_status)} " \
                       "expected #{@pending_needed} data byte(s), got #{@pending_data.length}"
        end
        reset
        []
      end

      private

      def reset
        @running_status = nil # Last channel voice status byte
        @sysex_data = nil     # Array while a sysex dump is accumulating
        reset_message
      end

      # Clear the partially assembled non-sysex message only.
      def reset_message
        @pending_status = nil
        @pending_data = []
        @pending_needed = 0
      end

      def process_byte(byte, events)
        unless byte.is_a?(Integer) && byte >= 0 && byte <= 255
          raise Error, "invalid byte: #{byte.inspect} (expected 0-255)"
        end

        # System realtime bytes are single-byte messages. They are emitted
        # right away regardless of parser state and never alter running
        # status or any message in progress.
        if byte >= 0xF8
          events << make_realtime(byte)
          return
        end

        if @sysex_data
          handle_sysex_byte(byte, events)
        elsif byte >= 0x80
          handle_status(byte, events)
        else
          handle_data(byte, events)
        end
      end

      def handle_sysex_byte(byte, events)
        case byte
        when EOX
          data = @sysex_data
          @sysex_data = nil
          reset_message
          # 0xF0 cleared running status when the dump began; keep it clear.
          @running_status = nil
          events << SystemExclusive.new(data)
        when SYSEX
          raise Error, 'unexpected 0xF0 inside a system exclusive message'
        else
          if byte >= 0x80
            raise Error, format('status byte 0x%02x inside unterminated system exclusive', byte)
          end
          if @sysex_data.length >= @max_sysex_bytes
            raise Error, "system exclusive message exceeds maximum of #{@max_sysex_bytes} bytes"
          end
          @sysex_data << byte
        end
      end

      def handle_status(byte, events)
        case byte
        when SYSEX
          # 0xF0 starts a system exclusive dump and clears running status.
          reset_message
          @running_status = nil
          @sysex_data = []
        when MTC_QUARTER_FRAME
          start_system_common(byte, 1)
        when SONG_POINTER
          start_system_common(byte, 2)
        when SONG_SELECT
          start_system_common(byte, 1)
        when TUNE_REQUEST
          reset_message
          @running_status = nil
          events << TuneRequest.new
        when 0xF4, 0xF5
          raise Error, format('undefined system common status byte 0x%02x', byte)
        when EOX
          raise Error, 'unexpected end of system exclusive (0xF7) without 0xF0'
        when 0x80..0xEF
          # A new channel voice status aborts any partially assembled
          # message and becomes the running status.
          @running_status = byte
          @pending_status = byte
          @pending_data = []
          @pending_needed = CHANNEL_DATA_BYTES[(byte >> 4) & 0x0f]
        else
          raise Error, format('unexpected status byte 0x%02x', byte)
        end
      end

      # Remember a system common status that needs data bytes. Running
      # status has already been cleared by the caller.
      def start_system_common(status, needed)
        @pending_status = status
        @pending_data = []
        @pending_needed = needed
      end

      def handle_data(byte, events)
        unless @pending_status
          # No explicit status in progress: try channel running status.
          if @running_status
            @pending_status = @running_status
            @pending_data = []
            @pending_needed = CHANNEL_DATA_BYTES[(@running_status >> 4) & 0x0f]
          else
            raise Error, format('data byte 0x%02x without a status byte', byte)
          end
        end

        @pending_data << byte
        return unless @pending_data.length == @pending_needed

        emit_pending(events)
      end

      def emit_pending(events)
        status = @pending_status
        data = @pending_data
        if status <= 0xEF
          events << make_channel_event(status, data)
          # Keep channel running status; only clear the assembly state.
          reset_message
        else
          events << make_system_common_event(status, data)
          # A completed system common message clears running status.
          reset
        end
      end

      def make_channel_event(status, data)
        channel = status & 0x0f
        case status & 0xf0
        when NOTE_OFF then NoteOff.new(channel, data[0], data[1])
        when NOTE_ON then NoteOn.new(channel, data[0], data[1])
        when POLY_PRESSURE then PolyPressure.new(channel, data[0], data[1])
        when CONTROLLER then Controller.new(channel, data[0], data[1])
        when PITCH_BEND then PitchBend.new(channel, (data[1] << 7) + data[0])
        when PROGRAM_CHANGE then ProgramChange.new(channel, data[0])
        when CHANNEL_PRESSURE then ChannelPressure.new(channel, data[0])
        end
      end

      def make_system_common_event(status, data)
        case status
        when SONG_POINTER then SongPointer.new((data[1] << 7) + data[0])
        when SONG_SELECT then SongSelect.new(data[0])
        when MTC_QUARTER_FRAME then SystemCommon.new(status, 0, [data[0]])
        end
      end

      def make_realtime(byte)
        case byte
        when CLOCK then Clock.new
        when START then Start.new
        when CONTINUE then Continue.new
        when STOP then Stop.new
        when ACTIVE_SENSE then ActiveSense.new
        when SYSTEM_RESET then SystemReset.new
        else Realtime.new(byte, 0)
        end
      end
    end
  end
end
