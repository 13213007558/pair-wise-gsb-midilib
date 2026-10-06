require_relative 'consts'
require_relative 'event'

module MIDI
  # Raised when a MIDI Tuning Standard message or tuning value is malformed.
  class TuningError < StandardError; end

  # A readable 128-entry tuning table. Each entry maps a MIDI note number
  # (0-127) to a pitch expressed in fractional semitones (for example,
  # 60.5 is C4 raised by a quarter tone). The default table is twelve-tone
  # equal temperament, where every note maps to its own number.
  #
  # Pitches are encoded in MIDI Tuning Standard messages as one semitone
  # byte plus a 14-bit fraction of a semitone, so the wire resolution is
  # 1/16384 of a semitone (about 0.006 cents).
  class Tuning
    # Number of entries in the table (one per MIDI note number).
    NOTE_COUNT = 128
    # Number of ASCII name characters stored in a bulk tuning dump.
    NAME_LENGTH = 16
    # Bits used by the fractional part of an encoded pitch.
    FRACTION_BITS = 14
    # Number of fraction steps per semitone (2 ** FRACTION_BITS).
    FRACTION_SCALE = 1 << FRACTION_BITS
    # Maximum error introduced by encoding and decoding a pitch.
    ENCODING_TOLERANCE = 0.5 / FRACTION_SCALE
    # The three-byte "no change" sentinel used in place of a pitch.
    NO_CHANGE_BYTES = [0x7f, 0x7f, 0x7f].freeze

    # The tuning name (up to NAME_LENGTH ASCII characters).
    attr_accessor :name
    # The tuning program number (0-127) this table is stored under.
    attr_reader :program

    def initialize(name: '', program: 0)
      @name = name
      self.program = program
      @pitches = Array.new(NOTE_COUNT) { |note| note.to_f }
    end

    def program=(program)
      Tuning.validate_byte!(program, 'tuning program')
      @program = program
    end

    # Returns the pitch (in fractional semitones) for +note+.
    def [](note)
      Tuning.validate_note!(note)
      @pitches[note]
    end

    # Sets the pitch (in fractional semitones) for +note+.
    def []=(note, pitch)
      Tuning.validate_note!(note)
      @pitches[note] = Tuning.validate_pitch!(pitch)
    end

    # Yields +note+, +pitch+ for each of the 128 entries.
    def each
      return enum_for(:each) unless block_given?

      @pitches.each_with_index { |pitch, note| yield note, pitch }
    end

    # Returns true when every entry of both tables is within the MTS wire
    # resolution of the other.
    def equivalent_to?(other, tolerance: ENCODING_TOLERANCE)
      NOTE_COUNT.times.all? do |note|
        (self[note] - other[note]).abs <= tolerance
      end
    end

    # Returns a TuningBulkDump event carrying this table.
    def to_bulk_dump(device_id: SYSEX_ALL_DEVICES, program: @program,
                     name: @name, delta_time: 0)
      TuningBulkDump.new(self, device_id: device_id, program: program,
                         name: name, delta_time: delta_time)
    end

    # Returns a SingleNoteTuningChange event carrying this table's pitches
    # for +notes+.
    def to_single_note_change(notes, device_id: SYSEX_ALL_DEVICES,
                              program: @program, realtime: false,
                              delta_time: 0)
      changes = {}
      notes.each { |note| changes[note] = self[note] }
      SingleNoteTuningChange.new(changes, device_id: device_id,
                                 program: program, realtime: realtime,
                                 delta_time: delta_time)
    end

    # Raises TuningError unless +note+ is an integer in 0...NOTE_COUNT.
    # Out-of-range notes are never silently wrapped modulo 128, because
    # that would turn an illegal note into a different, legal one.
    def self.validate_note!(note)
      return if note.is_a?(Integer) && note >= 0 && note < NOTE_COUNT

      raise TuningError, "illegal note number: #{note.inspect}"
    end

    # Raises TuningError unless +pitch+ is a real number in
    # 0...NOTE_COUNT. Returns the pitch as a Float.
    def self.validate_pitch!(pitch)
      unless pitch.is_a?(Numeric) && !pitch.is_a?(Complex) &&
             pitch.finite? && pitch >= 0 && pitch < NOTE_COUNT
        raise TuningError, "illegal pitch: #{pitch.inspect}"
      end
      pitch.to_f
    end

    # Raises TuningError unless +val+ is an integer in 0..127.
    def self.validate_byte!(val, what)
      return if val.is_a?(Integer) && val >= 0 && val <= 0x7f

      raise TuningError, "illegal #{what}: #{val.inspect}"
    end

    # Encodes a pitch in fractional semitones as the three MTS bytes
    # [semitone, fraction MSB, fraction LSB].
    def self.encode_pitch(pitch)
      pitch = validate_pitch!(pitch)
      semitone = pitch.floor
      fraction = ((pitch - semitone) * FRACTION_SCALE).round
      if fraction >= FRACTION_SCALE # rounding carried into the next semitone
        semitone += 1
        fraction = 0
        raise TuningError, "illegal pitch: #{pitch.inspect}" if semitone >= NOTE_COUNT
      end
      [semitone, (fraction >> 7) & 0x7f, fraction & 0x7f]
    end

    # Decodes three MTS pitch bytes into fractional semitones. Returns nil
    # for the "no change" sentinel. Raises TuningError for out-of-range
    # fraction values instead of wrapping them into a legal pitch.
    def self.decode_pitch(bytes)
      raise TuningError, "illegal pitch data: #{bytes.inspect}" unless bytes.is_a?(Array) && bytes.length == 3
      return nil if no_change?(bytes)

      semitone, msb, lsb = bytes
      [semitone, msb, lsb].each do |byte|
        validate_byte!(byte, 'pitch byte')
      end
      fraction = (msb << 7) | lsb
      if fraction >= FRACTION_SCALE
        raise TuningError, "illegal pitch fraction: #{bytes.inspect}"
      end
      semitone + (fraction.to_f / FRACTION_SCALE)
    end

    # Returns true when +bytes+ is the three-byte "no change" sentinel.
    def self.no_change?(bytes)
      bytes == NO_CHANGE_BYTES
    end
  end

  # A MIDI Tuning Standard bulk tuning dump (non-realtime sub-ID 08 01).
  # This is a SystemExclusive event, so it can be placed on a track and
  # written to a Standard MIDI File like any other event.
  class TuningBulkDump < SystemExclusive
    # The device ID this dump is addressed to (0x7f means all devices).
    attr_reader :device_id
    # The tuning program number (0-127) this dump stores.
    attr_reader :program
    # The 16-character ASCII tuning name.
    attr_reader :tuning_name
    # The Tuning carried by this dump.
    attr_reader :tuning

    def initialize(tuning, device_id: SYSEX_ALL_DEVICES, program: nil,
                   name: nil, delta_time: 0)
      Tuning.validate_byte!(device_id, 'device ID')
      @device_id = device_id
      @program = program.nil? ? tuning.program : program
      Tuning.validate_byte!(@program, 'tuning program')
      @tuning_name = (name || tuning.name).to_s[0, Tuning::NAME_LENGTH]
      @tuning = tuning
      super(build_data, delta_time)
    end

    # The XOR checksum of all message bytes between the leading SYSEX
    # byte and the checksum itself.
    def checksum
      TuningBulkDump.compute_checksum(@data[0...-1])
    end

    # Parses a bulk tuning dump from a byte array (with or without the
    # SYSEX/EOX framing bytes) or a SystemExclusive event. Raises
    # TuningError when the message is malformed or the checksum fails.
    def self.parse(source)
      data = MTS.payload(source)
      expected_length = 5 + Tuning::NAME_LENGTH + (Tuning::NOTE_COUNT * 3) + 1
      unless data[0] == SYSEX_NON_REALTIME &&
             data[2..3] == [SUB_ID_MIDI_TUNING, MTS_BULK_TUNING_DUMP] &&
             data.length == expected_length
        raise TuningError, 'not a bulk tuning dump'
      end
      unless compute_checksum(data[0...-1]) == data[-1]
        raise TuningError, 'bulk tuning dump checksum mismatch'
      end

      device_id = data[1]
      program = data[4]
      name = data[5, Tuning::NAME_LENGTH].pack('C*').strip
      tuning = Tuning.new(name: name, program: program)
      Tuning::NOTE_COUNT.times do |note|
        offset = 5 + Tuning::NAME_LENGTH + (note * 3)
        pitch = Tuning.decode_pitch(data[offset, 3])
        # A "no change" entry keeps the default (equal tempered) pitch.
        tuning[note] = pitch unless pitch.nil?
      end
      new(tuning, device_id: device_id, program: program, name: name)
    end

    # Computes the XOR checksum over +bytes+.
    def self.compute_checksum(payload)
      payload.reduce(0) { |sum, byte| sum ^ byte } & 0x7f
    end

    private

    def build_data
      # The event data excludes the SYSEX/EOX framing bytes so that the
      # inherited data_as_bytes produces a well-formed SMF sysex message.
      data = [SYSEX_NON_REALTIME, @device_id, SUB_ID_MIDI_TUNING,
              MTS_BULK_TUNING_DUMP, @program]
      name_bytes = @tuning_name.bytes[0, Tuning::NAME_LENGTH]
      name_bytes += [0x20] * (Tuning::NAME_LENGTH - name_bytes.length)
      data.concat(name_bytes)
      @tuning.each { |_note, pitch| data.concat(Tuning.encode_pitch(pitch)) }
      data << TuningBulkDump.compute_checksum(data)
      data
    end
  end

  # A MIDI Tuning Standard single note tuning change. The realtime
  # variant (realtime sub-ID 08 01) re-tunes already sounding notes;
  # the non-realtime variant (non-realtime sub-ID 08 02) only affects
  # notes started after the message is received. See TuningState#apply.
  class SingleNoteTuningChange < SystemExclusive
    # The device ID this change is addressed to (0x7f means all devices).
    attr_reader :device_id
    # The tuning program number (0-127) this change edits.
    attr_reader :program
    # Hash mapping note numbers to pitches in fractional semitones.
    # A value of :no_change marks a "no change" sentinel entry.
    attr_reader :changes

    def initialize(changes, device_id: SYSEX_ALL_DEVICES, program: 0,
                   realtime: false, delta_time: 0)
      Tuning.validate_byte!(device_id, 'device ID')
      Tuning.validate_byte!(program, 'tuning program')
      raise TuningError, 'too many changes (max 127)' if changes.length > 0x7f

      @device_id = device_id
      @program = program
      @realtime = realtime ? true : false
      @changes = {}
      changes.each do |note, pitch|
        Tuning.validate_note!(note)
        @changes[note] = no_change_value?(pitch) ? :no_change : Tuning.validate_pitch!(pitch)
      end
      super(build_data, delta_time)
    end

    # True when this is the realtime variant, which re-tunes notes that
    # are already sounding. The non-realtime variant only affects notes
    # started after the message is received.
    def realtime?
      @realtime
    end

    # Parses a single note tuning change from a byte array (with or
    # without the SYSEX/EOX framing bytes) or a SystemExclusive event.
    # Raises TuningError when the message is malformed.
    def self.parse(source)
      data = MTS.payload(source)
      realtime =
        case data[0]
        when SYSEX_REALTIME then true
        when SYSEX_NON_REALTIME then false
        else
          raise TuningError, 'not a single note tuning change'
        end
      sub_id_2 = realtime ? MTS_SINGLE_NOTE_TUNING_CHANGE_RT : MTS_SINGLE_NOTE_TUNING_CHANGE
      unless data[2] == SUB_ID_MIDI_TUNING && data[3] == sub_id_2
        raise TuningError, 'not a single note tuning change'
      end
      count = data[5]
      unless count.is_a?(Integer) && data.length == 6 + (count * 4)
        raise TuningError, 'malformed single note tuning change'
      end

      changes = {}
      count.times do |i|
        offset = 6 + (i * 4)
        note = data[offset]
        Tuning.validate_note!(note)
        pitch_bytes = data[offset + 1, 3]
        changes[note] = Tuning.no_change?(pitch_bytes) ? :no_change : Tuning.decode_pitch(pitch_bytes)
      end
      new(changes, device_id: data[1], program: data[4], realtime: realtime)
    end

    private

    def no_change_value?(pitch)
      pitch.nil? || pitch == :no_change
    end

    def build_data
      # The event data excludes the SYSEX/EOX framing bytes so that the
      # inherited data_as_bytes produces a well-formed SMF sysex message.
      data = [@realtime ? SYSEX_REALTIME : SYSEX_NON_REALTIME,
              @device_id, SUB_ID_MIDI_TUNING,
              @realtime ? MTS_SINGLE_NOTE_TUNING_CHANGE_RT : MTS_SINGLE_NOTE_TUNING_CHANGE,
              @program, @changes.length]
      @changes.each do |note, pitch|
        data << note
        data.concat(pitch == :no_change ? Tuning::NO_CHANGE_BYTES : Tuning.encode_pitch(pitch))
      end
      data
    end
  end

  # Tracks a current tuning table plus the set of sounding notes, and
  # applies MTS messages to it. The semantics for already sounding notes
  # are explicit:
  #
  # * A TuningBulkDump replaces the whole table. Like all non-realtime
  #   messages, it does not re-tune sounding notes; they keep their pitch
  #   until they are re-triggered.
  # * A non-realtime SingleNoteTuningChange edits the table without
  #   affecting sounding notes.
  # * A realtime SingleNoteTuningChange edits the table and re-tunes any
  #   sounding notes it touches.
  #
  # #apply returns the list of sounding notes whose tuning changed, so
  # the caller knows exactly which voices must be re-tuned. It is always
  # empty for non-realtime messages.
  class TuningState
    # The current tuning table.
    attr_reader :tuning

    def initialize(tuning = Tuning.new)
      @tuning = tuning
      @sounding = []
    end

    def note_on(note)
      Tuning.validate_note!(note)
      @sounding << note unless @sounding.include?(note)
    end

    def note_off(note)
      Tuning.validate_note!(note)
      @sounding.delete(note)
    end

    # The currently sounding note numbers.
    def sounding
      @sounding.dup
    end

    def sounding?(note)
      @sounding.include?(note)
    end

    # Applies a TuningBulkDump or SingleNoteTuningChange to the table.
    # Returns the sounding notes whose tuning changed (always empty for
    # non-realtime messages).
    def apply(message)
      case message
      when TuningBulkDump
        @tuning = message.tuning
        []
      when SingleNoteTuningChange
        retune = []
        message.changes.each do |note, pitch|
          next if pitch == :no_change

          @tuning[note] = pitch
          retune << note if message.realtime? && sounding?(note)
        end
        retune
      else
        raise TuningError, "cannot apply #{message.class} to a tuning state"
      end
    end
  end

  # Helpers for recognizing and parsing MIDI Tuning Standard messages.
  module MTS
    # Parses a SystemExclusive event or byte array into a
    # TuningBulkDump or SingleNoteTuningChange. Returns nil when the
    # message is not an MTS message; raises TuningError when it looks
    # like one but is malformed (for example, a bad bulk dump checksum).
    def self.parse(source)
      data = payload(source)
      return nil unless data[2] == SUB_ID_MIDI_TUNING

      case data[0]
      when SYSEX_NON_REALTIME
        case data[3]
        when MTS_BULK_TUNING_DUMP then TuningBulkDump.parse(source)
        when MTS_SINGLE_NOTE_TUNING_CHANGE then SingleNoteTuningChange.parse(source)
        end
      when SYSEX_REALTIME
        SingleNoteTuningChange.parse(source) if data[3] == MTS_SINGLE_NOTE_TUNING_CHANGE_RT
      end
    end

    # Returns the message bytes without the SYSEX/EOX framing bytes.
    # Accepts a SystemExclusive event or a byte array with or without
    # framing. Raises TuningError for empty input.
    def self.payload(source)
      data = source.is_a?(SystemExclusive) ? source.data : source.to_a.dup
      raise TuningError, 'empty system exclusive message' if data.empty?

      data.shift if data[0] == SYSEX
      data.pop if data[-1] == EOX
      data
    end
  end
end
