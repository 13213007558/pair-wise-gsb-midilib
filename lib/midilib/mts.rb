# MIDI Tuning Standard (MMA RP-012) support.
#
# This file represents tuning values independently of MIDI channels and
# pitch bend messages. A MIDI::MTS::BulkTuningDump carries all 128 notes of
# a tuning program, while a MIDI::MTS::SingleNoteTuningChange carries one or
# more notes. Both message classes can be wrapped in MIDI::SystemExclusive
# events and written or read through the existing Standard MIDI File code.

require_relative 'event'

module MIDI
  module MTS
    # Non-real-time Universal System Exclusive manufacturer ID.
    NON_REALTIME_UNIVERSAL = 0x7E
    # Real-time Universal System Exclusive manufacturer ID.
    REALTIME_UNIVERSAL = 0x7F
    # Device ID that addresses every device.
    DEVICE_ID_BROADCAST = 0x7F

    # Device control sub-ID #1 for non-real-time bulk tuning messages.
    DEVICE_CONTROL_SUB_ID = 0x08
    # Non-real-time bulk tuning dump request sub-ID #2.
    BULK_TUNING_DUMP_REQUEST_SUB_ID = 0x00
    # Non-real-time bulk tuning dump sub-ID #2.
    BULK_TUNING_DUMP_SUB_ID = 0x01
    # Real-time single-note tuning change sub-ID #1. The non-real-time
    # version uses 0x07.
    SINGLE_NOTE_REALTIME_SUB_ID = 0x02
    SINGLE_NOTE_NON_REALTIME_SUB_ID = 0x07

    NOTE_COUNT = 128
    NAME_LENGTH = 16
    FRACTION_BITS = 14
    FRACTION_UNITS = 1 << FRACTION_BITS
    MAX_PITCH_WORD = (NOTE_COUNT << FRACTION_BITS) - 1

    # Frequency-data bytes that mean "do not change this note".
    NO_CHANGE_BYTES = [0x7F, 0x7F, 0x7F].freeze
    NO_CHANGE_WORD = (0x7F << FRACTION_BITS) |
                     (0x7F << 7) |
                     0x7F

    # Base class for errors detected while encoding or decoding MTS data.
    class Error < StandardError; end

    # Raised when a pitch, note number, device ID, or tuning program is not
    # legal. Values are rejected rather than wrapped with modulo so an
    # out-of-range number can never silently become another legal note.
    class InvalidValueError < Error; end

    # Raised when a system exclusive message is not a supported MTS message
    # or has an invalid length or structure.
    class FormatError < Error; end

    # Raised when a bulk tuning dump's checksum does not match its payload.
    class ChecksumError < FormatError; end

    # Encode or decode the 14-bit fractional pitch format. A pitch is a
    # MIDI note number expressed as a Numeric: 60 is middle C, 60.5 is one
    # equal-tempered semitone higher, and 60.01 is one cent higher.
    module PitchCodec
      module_function

      # Returns the exact pitch represented by the protocol word.
      def word_to_pitch(word)
        word.to_f / FRACTION_UNITS
      end

      # Rounds a pitch to the nearest protocol value and returns its
      # three seven-bit frequency-data bytes.
      def pitch_to_bytes(pitch)
        word = pitch_to_word(pitch)
        if word == NO_CHANGE_WORD
          raise InvalidValueError,
                "pitch #{pitch.inspect} is reserved as the no-change sentinel"
        end
        word_to_bytes(word)
      end

      # Returns the 21-bit protocol word for a Numeric pitch. The value is
      # rounded to the protocol's 2^-14 semitone resolution.
      def pitch_to_word(pitch)
        unless pitch.is_a?(Numeric) && !pitch.is_a?(Complex) && pitch.finite?
          raise InvalidValueError, "pitch must be a number, got #{pitch.inspect}"
        end

        units = (pitch * FRACTION_UNITS).round
        note = units >> FRACTION_BITS
        fraction = units & (FRACTION_UNITS - 1)

        if note == NOTE_COUNT && fraction.zero?
          raise InvalidValueError,
                "pitch #{pitch.inspect} is outside 0...#{NOTE_COUNT}"
        end
        unless note.between?(0, NOTE_COUNT - 1)
          raise InvalidValueError,
                "pitch #{pitch.inspect} is outside 0...#{NOTE_COUNT}"
        end

        (note << FRACTION_BITS) | fraction
      end

      def word_to_bytes(word)
        validate_seven_bit_word!(word)
        [
          (word >> FRACTION_BITS) & 0x7F,
          (word >> 7) & 0x7F,
          word & 0x7F
        ]
      end

      def bytes_to_word(bytes)
        bytes = Array(bytes)
        unless bytes.length == 3 && bytes.all? { |byte| seven_bit?(byte) }
          raise FormatError, 'frequency data must be three 7-bit bytes'
        end

        (bytes[0] << FRACTION_BITS) |
        (bytes[1] << 7) |
          bytes[2]
      end

      # Returns nil for the all-ones no-change sentinel, otherwise returns
      # the pitch represented by the bytes.
      def bytes_to_pitch(bytes)
        word = bytes_to_word(bytes)
        return nil if word == NO_CHANGE_WORD

        note = word >> FRACTION_BITS
        unless note.between?(0, NOTE_COUNT - 1)
          raise FormatError, "decoded note number #{note} is outside 0...#{NOTE_COUNT}"
        end

        word_to_pitch(word)
      end

      def no_change?(bytes)
        Array(bytes) == NO_CHANGE_BYTES
      end

      def validate_seven_bit_word!(word)
        unless word.is_a?(Integer) && word.between?(0, MAX_PITCH_WORD)
          raise InvalidValueError,
                "frequency word #{word.inspect} is outside 0..#{MAX_PITCH_WORD}"
        end
      end

      def seven_bit?(byte)
        byte.is_a?(Integer) && byte.between?(0, 0x7F)
      end
    end

    # A readable 128-note MIDI tuning table. Pitches are MIDI note numbers,
    # so the default table is equal temperament. Fractional values may be
    # supplied to retune individual notes. The optional ASCII +name+ is the
    # 16-byte name used by a bulk tuning dump.
    class TuningTable
      include Enumerable

      attr_reader :name

      # Accepts no arguments for a default table, a Hash of note => pitch,
      # an Array of 128 pitches, or a TuningTable to copy.
      def initialize(pitches = nil, name: nil)
        @pitches = Array.new(NOTE_COUNT) { |note| note }

        case pitches
        when nil
        when TuningTable
          @pitches = pitches.pitches.dup
          name ||= pitches.name
        when Hash
          pitches.each { |note, pitch| self[note] = pitch }
        when Array
          unless pitches.length == NOTE_COUNT
            raise InvalidValueError,
                  "tuning table must contain #{NOTE_COUNT} pitches"
          end
          pitches.each_with_index { |pitch, note| self[note] = pitch }
        else
          raise InvalidValueError, "unsupported tuning table #{pitches.inspect}"
        end

        self.name = name || ''
      end

      def name=(name)
        bytes = name_to_bytes(name)
        valid = bytes.all? { |byte| byte.is_a?(Integer) && byte.between?(0, 0x7F) }
        unless bytes.length <= NAME_LENGTH && valid
          raise InvalidValueError,
                "tuning name must be at most #{NAME_LENGTH} 7-bit ASCII bytes"
        end

        @name = bytes
        @name_bytes = bytes + Array.new(NAME_LENGTH - bytes.length, 0)
      end

      def name_string
        @name_bytes.pack('C*').sub(/\x00+\z/, '')
      end

      def [](note)
        validate_note!(note)
        @pitches[note]
      end

      def []=(note, pitch)
        validate_note!(note)
        bytes = PitchCodec.pitch_to_bytes(pitch)
        @pitches[note] = PitchCodec.bytes_to_pitch(bytes)
      end

      def each(&block)
        @pitches.each_with_index(&block)
      end

      def pitches
        @pitches.dup
      end

      def length
        @pitches.length
      end
      alias size length

      def to_a
        @pitches.dup
      end

      def ==(other)
        other.is_a?(TuningTable) &&
          name_bytes == other.name_bytes &&
          pitches == other.pitches
      end

      alias eql? ==

      def hash
        [name_bytes, @pitches].hash
      end

      # Encodes the 16-byte name followed by 128 three-byte frequency values.
      def encode_pitch_data
        name_bytes + @pitches.flat_map do |pitch|
          PitchCodec.pitch_to_bytes(pitch)
        end
      end

      # Creates a table from the 400 bytes of name and pitch data contained
      # in a bulk tuning dump. No-change sentinels are illegal in a complete
      # table and are rejected.
      def self.decode_pitch_data(bytes)
        bytes = Array(bytes)
        unless bytes.length == NAME_LENGTH + (NOTE_COUNT * 3)
          raise FormatError,
                "bulk tuning data must be #{NAME_LENGTH + NOTE_COUNT * 3} bytes"
        end

        name_bytes = bytes[0, NAME_LENGTH]
        unless name_bytes.all? { |byte| byte <= 0x7F }
          raise FormatError, 'tuning name contains bytes outside 0..127'
        end
        first_padding = name_bytes.index(0) || NAME_LENGTH
        unless name_bytes[first_padding..].all?(&:zero?)
          raise FormatError, 'tuning name contains data after NUL padding'
        end
        name = name_bytes[0, first_padding]
        table = new(name: name)
        NOTE_COUNT.times do |note|
          offset = NAME_LENGTH + (note * 3)
          pitch_bytes = bytes[offset, 3]
          pitch = PitchCodec.bytes_to_pitch(pitch_bytes)
          raise FormatError, "note #{note} contains a no-change sentinel" if pitch.nil?

          table[note] = pitch
        end
        table
      end

      protected

      attr_reader :name_bytes

      private

      def validate_note!(note)
        return if note.is_a?(Integer) && note.between?(0, NOTE_COUNT - 1)

        raise InvalidValueError, "note #{note.inspect} is outside 0...#{NOTE_COUNT}"
      end

      def name_to_bytes(name)
        case name
        when nil
          []
        when String
          name.bytes.to_a
        when Array
          name.dup
        else
          raise InvalidValueError, "tuning name must be a String or byte Array"
        end
      end
    end

    # Shared behavior for the MTS universal system exclusive messages
    # represented by this library.
    class MTSMessage
      attr_reader :device_id, :realtime

      def initialize(device_id, realtime)
        self.device_id = device_id
        @realtime = realtime ? true : false
      end

      def realtime?
        @realtime
      end

      def device_id=(device_id)
        validate_device_id!(device_id)
        @device_id = device_id
      end

      # Complete system exclusive bytes, including SYSEX and EOX.
      def sysex_bytes
        [0xF0] + payload + [0xF7]
      end

      def to_system_exclusive(delta_time = 0)
        MIDI::SystemExclusive.new(sysex_bytes, delta_time)
      end

      # Complete payload, without SYSEX/EOX framing. Implemented by each
      # concrete message because bulk and note-change layouts differ.
      def payload
        raise 'subclass responsibility'
      end

      def manufacturer_id
        realtime? ? REALTIME_UNIVERSAL : NON_REALTIME_UNIVERSAL
      end

      # Parses a complete system exclusive message, a payload without
      # framing, or a MIDI::SystemExclusive event. Returns a supported
      # MTSMessage subclass.
      def self.parse(message)
        bytes = normalize_message_bytes(message)
        case bytes[2]
        when DEVICE_CONTROL_SUB_ID
          case bytes[3]
          when BULK_TUNING_DUMP_REQUEST_SUB_ID
            BulkTuningDumpRequest.send(:parse_payload, bytes)
          when BULK_TUNING_DUMP_SUB_ID
            BulkTuningDump.send(:parse_payload, bytes)
          else
            raise FormatError,
                  format('unsupported device control sub-ID 0x%02X', bytes[3])
          end
        when SINGLE_NOTE_REALTIME_SUB_ID, SINGLE_NOTE_NON_REALTIME_SUB_ID
          SingleNoteTuningChange.send(:parse_payload, bytes)
        else
          raise FormatError,
                format('unsupported MTS sub-ID 0x%02X', bytes[2])
        end
      end

      def self.normalize_message_bytes(message) # :nodoc:
        bytes = case message
                when MIDI::SystemExclusive
                  message.data.dup
                when String
                  message.bytes.to_a
                else
                  Array(message).dup
                end
        bytes.shift if bytes.first == 0xF0
        bytes.pop if bytes.last == 0xF7
        if bytes.length < 4
          raise FormatError, 'MTS system exclusive message is too short'
        end
        unless expected_header?(bytes)
          raise FormatError, 'not an MTS universal system exclusive message'
        end
        bytes
      end

      def self.expected_header?(bytes) # :nodoc:
        universal = case bytes[2]
                    when DEVICE_CONTROL_SUB_ID
                      NON_REALTIME_UNIVERSAL
                    when SINGLE_NOTE_REALTIME_SUB_ID
                      REALTIME_UNIVERSAL
                    when SINGLE_NOTE_NON_REALTIME_SUB_ID
                      NON_REALTIME_UNIVERSAL
                    end
        universal && bytes[0] == universal &&
          bytes[1].between?(0, DEVICE_ID_BROADCAST)
      end

      def self.validate_device_id_value(device_id) # :nodoc:
        return if device_id.between?(0, DEVICE_ID_BROADCAST)

        raise FormatError,
              "device ID #{device_id.inspect} is outside 0..#{DEVICE_ID_BROADCAST}"
      end

      private_class_method :normalize_message_bytes, :expected_header?

      private

      def sub_id
        raise 'subclass responsibility'
      end

      def validate_device_id!(device_id)
        return if device_id.is_a?(Integer) && device_id.between?(0, DEVICE_ID_BROADCAST)

        raise InvalidValueError,
              "device ID #{device_id.inspect} is outside 0..#{DEVICE_ID_BROADCAST}"
      end

      def validate_program!(program)
        return if program.is_a?(Integer) && program.between?(0, NOTE_COUNT - 1)

        raise InvalidValueError,
              "tuning program #{program.inspect} is outside 0...#{NOTE_COUNT}"
      end

      def self.validate_seven_bit!(byte, name) # :nodoc:
        return if byte.is_a?(Integer) && byte.between?(0, 0x7F)

        raise FormatError, "#{name} byte #{byte.inspect} is outside 0..127"
      end
    end

    # Sub-ID #8: non-real-time bulk tuning dump. This message defines all
    # 128 pitches in one tuning program. It is non-real-time: devices apply
    # it to subsequently played notes and do not retune notes already
    # sounding.
    class BulkTuningDump < MTSMessage
      PITCH_DATA_LENGTH = NAME_LENGTH + (NOTE_COUNT * 3)
      CHECKSUMED_LENGTH = 1 + PITCH_DATA_LENGTH
      PAYLOAD_LENGTH = 4 + PITCH_DATA_LENGTH + 1

      attr_reader :table

      def initialize(table = nil, device_id: 0, name: nil)
        super(device_id, false)
        @table = case table
                 when TuningTable
                   table
                 when Hash, Array, nil
                   TuningTable.new(table, name: name)
                 else
                   raise InvalidValueError,
                         "unsupported tuning table #{table.inspect}"
                 end
      end

      def checksum
        self.class.checksum_for(BULK_TUNING_DUMP_SUB_ID, table.encode_pitch_data)
      end

      def payload
        [manufacturer_id, device_id, DEVICE_CONTROL_SUB_ID, sub_id] +
          table.encode_pitch_data + [checksum]
      end

      # The MTS checksum is the 7-bit two's-complement of the sum of the
      # sub-ID #2 byte, 16-byte name, and 384 frequency-data bytes.
      def self.checksum_for(sub_id_byte, pitch_data)
        bytes = [sub_id_byte] + Array(pitch_data)
        unless bytes.length == CHECKSUMED_LENGTH &&
               bytes.all? { |byte| byte.is_a?(Integer) && byte.between?(0, 0x7F) }
          raise FormatError,
                "checksum data must be #{CHECKSUMED_LENGTH} 7-bit bytes"
        end

        (-bytes.sum) & 0x7F
      end

      def self.parse_payload(bytes) # :nodoc:
        unless bytes.length == PAYLOAD_LENGTH
          raise FormatError,
                "bulk tuning dump must be #{PAYLOAD_LENGTH} payload bytes"
        end
        unless bytes[0] == NON_REALTIME_UNIVERSAL &&
               bytes[2] == DEVICE_CONTROL_SUB_ID &&
               bytes[3] == BULK_TUNING_DUMP_SUB_ID
          raise FormatError, 'not a non-real-time bulk tuning dump'
        end
        validate_device_id_value(bytes[1])

        device_id = bytes[1]
        sub_id_byte = bytes[3]
        pitch_data = bytes[4, PITCH_DATA_LENGTH]
        checksum = bytes[4 + PITCH_DATA_LENGTH]
        validate_seven_bit!(checksum, 'checksum')

        expected = checksum_for(sub_id_byte, pitch_data)
        unless checksum == expected
          raise ChecksumError,
                format('bulk tuning checksum 0x%02X does not match 0x%02X',
                       checksum, expected)
        end

        table = TuningTable.decode_pitch_data(pitch_data)
        dump = allocate
        dump.send(:initialize_parsed, device_id, table)
        dump
      end

      private

      def initialize_parsed(device_id, table)
        @device_id = device_id
        @realtime = false
        @table = table
        validate_device_id!(device_id)
      end

      def sub_id
        BULK_TUNING_DUMP_SUB_ID
      end
    end

    # Sub-ID #0: non-real-time bulk tuning dump request. The request names
    # the tuning program a device should send back. It is provided so a
    # received dump can be associated with a program when saving or applying
    # tuning state.
    class BulkTuningDumpRequest < MTSMessage
      PAYLOAD_LENGTH = 7

      attr_reader :tuning_program

      def initialize(tuning_program = 0, device_id: 0)
        super(device_id, false)
        self.tuning_program = tuning_program
      end

      def tuning_program=(tuning_program)
        validate_program!(tuning_program)
        @tuning_program = tuning_program
      end

      def payload
        [manufacturer_id, device_id, DEVICE_CONTROL_SUB_ID, sub_id,
         0x00, 0x00, tuning_program]
      end

      def self.parse_payload(bytes) # :nodoc:
        unless bytes.length == PAYLOAD_LENGTH &&
               bytes[0] == NON_REALTIME_UNIVERSAL &&
               bytes[2] == DEVICE_CONTROL_SUB_ID &&
               bytes[3] == BULK_TUNING_DUMP_REQUEST_SUB_ID &&
               bytes[4] == 0x00 && bytes[5] == 0x00
          raise FormatError, 'not a bulk tuning dump request'
        end
        validate_device_id_value(bytes[1])
        unless bytes[6].between?(0, NOTE_COUNT - 1)
          raise FormatError, "tuning program #{bytes[6]} is outside 0...#{NOTE_COUNT}"
        end

        request = allocate
        request.send(:initialize_parsed, bytes[1], bytes[6])
        request
      end

      private

      def initialize_parsed(device_id, tuning_program)
        validate_device_id!(device_id)
        validate_program!(tuning_program)
        @device_id = device_id
        @realtime = false
        @tuning_program = tuning_program
      end

      def sub_id
        BULK_TUNING_DUMP_REQUEST_SUB_ID
      end
    end

    # Sub-ID #2 (real time) or #7 (non real time): single-note tuning
    # change. A real-time message changes all currently sounding occurrences
    # of its notes immediately. A non-real-time message updates the tuning
    # table only and affects subsequently played notes.
    class SingleNoteTuningChange < MTSMessage
      MAX_CHANGES = 127

      # Array of [note_number, pitch_or_nil]. Nil pitch means "no change".
      attr_reader :changes, :tuning_program

      def initialize(changes, tuning_program: 0, device_id: 0,
                     realtime: true)
        super(device_id, realtime)
        self.tuning_program = tuning_program
        self.changes = changes
      end

      def tuning_program=(tuning_program)
        validate_program!(tuning_program)
        @tuning_program = tuning_program
      end

      def changes=(changes)
        entries = normalize_changes(changes)
        notes = entries.map(&:first)
        duplicates = notes.group_by(&:itself).select { |_, group| group.length > 1 }.keys
        unless duplicates.empty?
          raise InvalidValueError,
                "duplicate notes in tuning change: #{duplicates.sort.inspect}"
        end
        @changes = entries
      end

      def changed_notes
        changes.reject { |_note, pitch| pitch.nil? }.map(&:first)
      end

      def change_count
        changes.length
      end

      def to_h
        changes.each_with_object({}) { |(note, pitch), hash| hash[note] = pitch }
      end

      def payload
        [manufacturer_id, device_id, sub_id, model_id, tuning_program] +
          message_payload
      end

      def self.parse_payload(bytes) # :nodoc:
        sub_id = bytes[2]
        realtime = sub_id == SINGLE_NOTE_REALTIME_SUB_ID
        unless [SINGLE_NOTE_REALTIME_SUB_ID,
                SINGLE_NOTE_NON_REALTIME_SUB_ID].include?(sub_id)
          raise FormatError, 'not a single-note tuning change'
        end
        if bytes.length < 6
          raise FormatError, 'single-note tuning message is too short'
        end
        unless bytes[3] == 0x7F
          raise FormatError, 'single-note tuning model ID must be 0x7F'
        end

        tuning_program = bytes[4]
        count = bytes[5]
        validate_device_id_value(bytes[1])
        unless tuning_program.between?(0, NOTE_COUNT - 1)
          raise FormatError,
                "tuning program #{tuning_program} is outside 0...#{NOTE_COUNT}"
        end
        unless count.between?(1, MAX_CHANGES) &&
               bytes.length == expected_length(count)
          raise FormatError,
                "single-note tuning length does not match #{count} changes"
        end

        changes = count.times.map do |index|
          offset = 6 + (index * 4)
          note = bytes[offset]
          unless note.between?(0, NOTE_COUNT - 1)
            raise FormatError, "note #{note} is outside 0...#{NOTE_COUNT}"
          end
          pitch = PitchCodec.bytes_to_pitch(bytes[offset + 1, 3])
          [note, pitch]
        end

        message = allocate
        message.send(:initialize_parsed, bytes[1], tuning_program, realtime,
                     changes)
        message
      end

      def self.expected_length(count)
        6 + (count * 4)
      end

      private

      def initialize_parsed(device_id, tuning_program, realtime, changes)
        validate_device_id!(device_id)
        validate_program!(tuning_program)
        @device_id = device_id
        @tuning_program = tuning_program
        @realtime = realtime
        @changes = changes
      end

      def model_id
        0x7F
      end

      def normalize_changes(changes)
        entries = case changes
                  when Hash
                    changes.to_a
                  else
                    Array(changes)
                  end
        if entries.empty? || entries.length > MAX_CHANGES
          raise InvalidValueError,
                "single-note tuning must contain 1..#{MAX_CHANGES} changes"
        end

        entries.map do |entry|
          note, pitch = entry
          unless note.is_a?(Integer) && note.between?(0, NOTE_COUNT - 1)
            raise InvalidValueError, "note #{note.inspect} is outside 0...#{NOTE_COUNT}"
          end
          if pitch.nil?
            [note, nil]
          else
            bytes = PitchCodec.pitch_to_bytes(pitch)
            [note, PitchCodec.bytes_to_pitch(bytes)]
          end
        end
      end

      def sub_id
        realtime? ? SINGLE_NOTE_REALTIME_SUB_ID : SINGLE_NOTE_NON_REALTIME_SUB_ID
      end

      def message_payload
        encoded = changes.flat_map do |note, pitch|
          bytes = pitch.nil? ? NO_CHANGE_BYTES.dup : PitchCodec.pitch_to_bytes(pitch)
          [note] + bytes
        end
        [change_count] + encoded
      end
    end

    # Describes what happened when an MTS message was applied to a
    # TuningState. +affected_sounding_notes+ contains [channel, note] pairs
    # for notes already sounding when a real-time single-note change arrived.
    TuningUpdate = Struct.new(:message, :tuning_program, :changed_notes,
                              :affected_sounding_notes, :realtime,
                              keyword_init: true) do
      def sounding_notes_affected?
        !affected_sounding_notes.empty?
      end
    end

    # Applies MTS messages to an in-memory collection of 128 tuning
    # programs. Note-on and note-off tracking lets the state report which
    # currently sounding notes are affected by a real-time single-note
    # change. MTS tuning messages are channel-independent, but sounding note
    # instances are reported as [channel, note] pairs.
    class TuningState
      def initialize(default_table: TuningTable.new)
        @tables = Hash.new do |hash, program|
          valid_program!(program)
          hash[program] = TuningTable.new
        end
        @sounding = Hash.new(0)
        replace(default_table, 0)
      end

      def [](tuning_program)
        @tables[valid_program!(tuning_program)]
      end

      def replace(table, tuning_program = 0)
        valid_program!(tuning_program)
        table = TuningTable.new(table) unless table.is_a?(TuningTable)
        @tables[tuning_program] = table
        table
      end

      def pitch(tuning_program, note)
        @tables[valid_program!(tuning_program)][valid_note!(note)]
      end

      def note_on(channel, note)
        key = [valid_channel!(channel), valid_note!(note)]
        @sounding[key] += 1
        nil
      end

      def note_off(channel, note)
        key = [valid_channel!(channel), valid_note!(note)]
        @sounding[key] -= 1 if @sounding.key?(key)
        @sounding.delete(key) if @sounding[key] <= 0
        nil
      end

      def sounding?(channel, note)
        @sounding.key?([channel, note])
      end

      def sounding_notes
        @sounding.keys.map(&:dup)
      end

      # Applies a parsed MTSMessage, or parses raw system exclusive bytes or
      # a MIDI::SystemExclusive event first. A bulk dump does not carry a
      # program number in the wire format; +tuning_program+ supplies the
      # program in which that dump is stored and defaults to zero.
      def apply(message, tuning_program: 0)
        message = MTSMessage.parse(message) unless message.is_a?(MTSMessage)

        case message
        when BulkTuningDumpRequest
          TuningUpdate.new(
            message: message,
            tuning_program: message.tuning_program,
            changed_notes: [],
            affected_sounding_notes: [],
            realtime: false
          )
        when BulkTuningDump
          program = valid_program!(tuning_program)
          replace(message.table, program)
          TuningUpdate.new(
            message: message,
            tuning_program: program,
            changed_notes: [],
            affected_sounding_notes: [],
            realtime: false
          )
        when SingleNoteTuningChange
          apply_single_note_change(message)
        else
          raise FormatError, "cannot apply #{message.class}"
        end
      end

      private

      def apply_single_note_change(message)
        program = valid_program!(message.tuning_program)
        table = @tables[program]
        changed = []

        message.changes.each do |note, pitch|
          next if pitch.nil?

          table[note] = pitch
          changed << note
        end

        affected = if message.realtime?
                     changed.flat_map do |note|
                       @sounding.keys.select do |_channel, sounding_note|
                         sounding_note == note
                       end
                     end
                   else
                     []
                   end

        TuningUpdate.new(
          message: message,
          tuning_program: program,
          changed_notes: changed,
          affected_sounding_notes: affected,
          realtime: message.realtime?
        )
      end

      def valid_program!(program)
        return program if program.is_a?(Integer) && program.between?(0, NOTE_COUNT - 1)

        raise InvalidValueError,
              "tuning program #{program.inspect} is outside 0...#{NOTE_COUNT}"
      end

      def valid_note!(note)
        return note if note.is_a?(Integer) && note.between?(0, NOTE_COUNT - 1)

        raise InvalidValueError, "note #{note.inspect} is outside 0...#{NOTE_COUNT}"
      end

      def valid_channel!(channel)
        return channel if channel.is_a?(Integer) && channel.between?(0, MIDI_CHANNELS - 1)

        raise InvalidValueError,
              "channel #{channel.inspect} is outside 0...#{MIDI_CHANNELS}"
      end
    end
  end
end
