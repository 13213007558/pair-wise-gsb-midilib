require_relative '../consts'
require_relative '../event'

module MIDI
  module IO
    # Parses a raw MIDI 1.0 byte stream delivered in arbitrary chunks.
    #
    # Unlike MIDIFile, this parser does not read MIDI file structures
    # (no MThd/MTrk headers, no chunks, and no delta-time bytes). Bytes
    # are handed to #feed in whatever-sized pieces arrive from the
    # device; messages may span any number of calls and may be split at
    # any byte boundary.
    #
    # Complete messages are turned into the library's Event objects
    # (NoteOn, Controller, PitchBend, SystemExclusive, Clock, and so on)
    # and returned from #feed (and/or passed to a callback). Events
    # carry no timing information; delta_time is always 0 and the caller
    # is expected to stamp each event with the time it was received.
    #
    # Channel voice running status is remembered until a channel mode
    # change: a system common (or system exclusive) status byte clears
    # it. System realtime bytes (0xf8-0xfe plus 0xff) are delivered
    # immediately even when they appear between the data bytes of
    # another message, without disturbing that message.
    #
    # System exclusive data is accumulated until EOX; #max_sysex_length
    # bounds the accumulated payload (not counting the leading 0xf0 and
    # trailing 0xf7) so a device that never ends a message cannot grow
    # the buffer without limit. #finish reports any incomplete message
    # instead of silently discarding it.
    class StreamParser
      # Default maximum number of accumulated SysEx payload bytes.
      DEFAULT_MAX_SYSEX_LENGTH = 1_048_576

      # Number of data bytes for each channel voice status, indexed by
      # the status value's high nibble (0x8..0xe).
      CHANNEL_DATA_LENGTHS = {
        NOTE_OFF => 2,
        NOTE_ON => 2,
        POLY_PRESSURE => 2,
        CONTROLLER => 2,
        PROGRAM_CHANGE => 1,
        CHANNEL_PRESSURE => 1,
        PITCH_BEND => 2
      }.freeze

      # Number of data bytes for each defined system common status.
      SYSTEM_COMMON_DATA_LENGTHS = {
        SONG_POINTER => 2,
        SONG_SELECT => 1,
        TUNE_REQUEST => 0
      }.freeze

      # Realtime status bytes mapped to their event classes.
      REALTIME_EVENTS = {
        CLOCK => Clock,
        START => Start,
        CONTINUE => Continue,
        STOP => Stop,
        ACTIVE_SENSE => ActiveSense,
        SYSTEM_RESET => SystemReset
      }.freeze

      class StreamParserError < StandardError
      end

      # Raised when a data byte (high bit clear) arrives where a status
      # byte is required and there is no running status to apply, or for
      # undefined/reserved status bytes.
      class IllegalDataByte < StreamParserError
      end

      # Raised when accumulated SysEx data exceeds #max_sysex_length.
      class SysexTooLong < StreamParserError
      end

      # Raised by #finish when bytes of an unfinished message remain.
      class TruncatedMessage < StreamParserError
      end

      # The block given to the constructor, if any. Used by #feed and
      # #finish when called without a block of their own.
      attr_reader :block

      # Maximum accumulated SysEx payload length in bytes.
      attr_accessor :max_sysex_length

      # The most recent channel voice status byte, or nil when running
      # status is not in effect.
      attr_reader :running_status

      # Create a new stream parser. The optional block is called with
      # each completed Event when #feed or #finish is invoked without a
      # block of their own. +max_sysex_length+ limits how many SysEx
      # payload bytes are accumulated before SysexTooLong is raised.
      def initialize(max_sysex_length = DEFAULT_MAX_SYSEX_LENGTH, &block)
        @block = block
        @max_sysex_length = max_sysex_length
        reset
      end

      # Forget all buffered bytes and running status, returning the
      # parser to its freshly-initialized state.
      def reset
        @running_status = nil
        @status = nil
        @needed = 0
        @data = []
        @sysex_data = nil
        @sysex_length = 0
        @finished = false
        self
      end

      # Feed one chunk of raw bytes. +bytes+ may be a binary String, an
      # array of integers, or any object that yields integer byte values.
      # Returns an array of the events completed while processing the
      # chunk. The given block (or the constructor block) is called with
      # each event as it is completed.
      def feed(bytes, &callback)
        raise IOError, 'cannot feed a finished parser' if @finished

        events = []
        emit = callback || @block
        each_byte(bytes) { |byte| process(byte, events, emit) }
        events
      end

      # Marks the stream complete. Any unfinished message raises
      # TruncatedMessage so it is not silently lost. Returns the events
      # flushed (normally none); a block behaves as in #feed.
      def finish(&callback)
        events = []
        emit = callback || @block

        if @sysex_data
          raise TruncatedMessage,
                "unfinished system exclusive message: #{@sysex_length} " \
                'payload byte(s) received without EOX'
        end

        if @status
          raise TruncatedMessage,
                "unfinished message status 0x#{format('%02x', @status)}: " \
                "#{@data.length} of #{@needed} data byte(s) received"
        end

        @finished = true
        events
      end

      # True after #finish has been called.
      def finished?
        @finished
      end

      private

      def each_byte(bytes, &block)
        case bytes
        when String
          bytes.each_byte(&block)
        when Array
          bytes.each(&block)
        else
          bytes.each(&block)
        end
      end

      def emit_event(event, events, callback)
        events << event
        callback.call(event) if callback
      end

      def process(byte, events, callback)
        if byte >= 0xf8
          process_realtime(byte, events, callback)
        elsif byte >= 0x80
          process_status(byte, events, callback)
        else
          process_data(byte, events, callback)
        end
      end

      def process_realtime(byte, events, callback)
        event_class = REALTIME_EVENTS.fetch(byte) do
          raise IllegalDataByte,
                "undefined realtime status byte 0x#{format('%02x', byte)}"
        end
        # Realtime messages do not affect running status or any message
        # being assembled, even when they arrive between its data bytes.
        emit_event(event_class.new, events, callback)
      end

      def process_status(byte, events, callback)
        case byte
        when SYSEX
          start_sysex
        when EOX
          if @sysex_data
            data = @sysex_data
            @sysex_data = nil
            @sysex_length = 0
            # SysEx is a system common category message, so it clears
            # channel voice running status.
            @running_status = nil
            emit_event(SystemExclusive.new(data), events, callback)
          else
            @running_status = nil
            emit_event(SystemCommon.new(EOX), events, callback)
          end
        else
          # A status byte arriving mid-SysEx (other than realtime/EOX)
          # is illegal.
          if @sysex_data
            raise IllegalDataByte,
                  "status byte 0x#{format('%02x', byte)} received before " \
                  'system exclusive EOX'
          end

          if byte < 0xf0
            # Channel voice status: begin a new channel message.
            needed = channel_data_length(byte)
            start_message(byte, needed, events, callback)
          else
            # A system common status cancels running status.
            @running_status = nil
            needed = SYSTEM_COMMON_DATA_LENGTHS.fetch(byte) do
              raise IllegalDataByte,
                    "undefined system common status byte 0x#{format('%02x', byte)}"
            end
            start_message(byte, needed, events, callback)
          end
        end
      end

      def start_sysex
        # A new F0 replaces any partially accumulated SysEx and clears
        # channel voice running status.
        @running_status = nil
        @status = nil
        @data = []
        @sysex_data = []
        @sysex_length = 0
      end

      def start_message(status, needed, events, callback)
        @status = status
        @needed = needed
        @data = []
        complete_message(events, callback) if needed.zero?
      end

      def process_data(byte, events, callback)
        if @sysex_data
          add_sysex_byte(byte)
        elsif @status
          @data << byte
          complete_message(events, callback) if @data.length == @needed
        elsif @running_status
          @status = @running_status
          @needed = channel_data_length(@status)
          @data = [byte]
          complete_message(events, callback) if @data.length == @needed
        else
          raise IllegalDataByte,
                "data byte 0x#{format('%02x', byte)} received without a status byte"
        end
      end

      def add_sysex_byte(byte)
        @sysex_length += 1
        if @sysex_length > @max_sysex_length
          raise SysexTooLong,
                "system exclusive message exceeds #{@max_sysex_length} byte limit"
        end
        @sysex_data << byte
      end

      def complete_message(events, callback)
        status = @status
        data = @data
        @status = nil
        @data = []

        if status >= 0xf0
          build_system_common(status, data, events, callback)
        else
          build_channel_message(status, data, events, callback)
          # Only channel voice messages establish running status.
          @running_status = status
        end
      end

      def channel_data_length(status)
        CHANNEL_DATA_LENGTHS.fetch(status & 0xf0) do
          raise IllegalDataByte,
                "illegal channel status byte 0x#{format('%02x', status)}"
        end
      end

      def build_channel_message(status, data, events, callback)
        channel = status & 0x0f
        event =
          case status & 0xf0
          when NOTE_OFF
            NoteOff.new(channel, data[0], data[1])
          when NOTE_ON
            if data[1].zero?
              # A note on with velocity 0 means note off, matching the
              # semantics used by the file reader.
              NoteOff.new(channel, data[0], 64)
            else
              NoteOn.new(channel, data[0], data[1])
            end
          when POLY_PRESSURE
            PolyPressure.new(channel, data[0], data[1])
          when CONTROLLER
            Controller.new(channel, data[0], data[1])
          when PROGRAM_CHANGE
            ProgramChange.new(channel, data[0])
          when CHANNEL_PRESSURE
            ChannelPressure.new(channel, data[0])
          when PITCH_BEND
            PitchBend.new(channel, (data[1] << 7) + data[0])
          end
        emit_event(event, events, callback)
      end

      def build_system_common(status, data, events, callback)
        event =
          case status
          when SONG_POINTER
            SongPointer.new((data[1] << 7) + data[0])
          when SONG_SELECT
            SongSelect.new(data[0])
          when TUNE_REQUEST
            TuneRequest.new
          else
            SystemCommon.new(status)
          end
        emit_event(event, events, callback)
      end
    end
  end
end
