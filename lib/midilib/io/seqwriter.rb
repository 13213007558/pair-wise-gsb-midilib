# Writes MIDI files.

require_relative '../event'
require_relative '../utils'
require_relative 'compact_order'

module MIDI
  module IO
    class SeqWriter
      # When +compact+ is true, events that share a start time may be
      # reordered so the file uses fewer bytes. See IO::CompactOrder.
      attr_reader :compact_report

      def initialize(seq, midi_format = 1, compact: false, &block) # :yields: num_tracks, index
        @seq = seq
        @midi_format = midi_format || 1
        @compact = compact
        @update_block = block
        @compact_report = nil
      end

      # Writes a MIDI format 1 file.
      def write_to(io)
        if @midi_format == 0
          # merge tracks before writing
          merged_seq = Sequence.new
          merged_track = Track.new(merged_seq)
          merged_seq.tracks << merged_track
          @seq.each do |track|
            merged_track.merge(track.events)
          end
          @seq = merged_seq # replace
        end

        @io = io
        @bytes_written = 0
        @compact_report = nil
        write_header
        @update_block.call(nil, @seq.tracks.length, 0) if @update_block
        @seq.tracks.each_with_index do |track, i|
          write_track(track)
          @update_block.call(track, @seq.tracks.length, i) if @update_block
        end
      end

      def write_header
        @io.print 'MThd'
        write32(6)
        write16(@midi_format) # Ignore sequence format; write as format 1 or 0, default 1
        write16(@seq.tracks.length)
        write16(@seq.ppqn)
      end

      def write_track(track)
        @io.print 'MTrk'
        track_size_file_pos = @io.tell
        write32(0)                # Dummy byte count; overwritten later
        @bytes_written = 0        # Reset after previous write

        write_instrument(track.instrument)

        pairs = event_write_order(track)

        prev_status = 0
        pairs.each do |event, delta_time|
          write_var_len(delta_time) unless event.is_a?(Realtime)

          data = event.data_as_bytes
          status = data[0] # status byte plus channel number, if any

          # running status byte
          status = possibly_munge_due_to_running_status_byte(data, prev_status)

          @bytes_written += write_bytes(data)

          prev_status = status
        end

        # Write track end event if the track doesn't have one.
        unless track.events.last.is_a?(MetaEvent) && track.events.last.meta_type == META_TRACK_END
          event = MetaEvent.new(META_TRACK_END)
          write_var_len(0)
          @bytes_written += write_bytes(event.data_as_bytes)
        end

        # Go back to beginning of track data and write number of bytes,
        # then come back here to end of file.
        @io.seek(track_size_file_pos)
        write32(@bytes_written)
        @io.seek(0, ::IO::SEEK_END)
      end

      # Returns [event, delta_time] pairs in the order they should be
      # written. With compact mode off this is the track's original order;
      # with compact mode on, simultaneous events may be reordered (see
      # IO::CompactOrder) and the reorder report is accumulated into
      # +compact_report+.
      def event_write_order(track)
        return track.events.map { |event| [event, event.delta_time] } unless @compact

        pairs, report = CompactOrder.reorder(track.events)
        accumulate_compact_report(report)
        pairs
      end

      # If we can use a running status byte, delete the status byte from
      # the given data. Return the status to remember for next time as the
      # running status byte for this event.
      def possibly_munge_due_to_running_status_byte(data, prev_status)
        status = data[0]
        return status if status >= 0xf0 || prev_status >= 0xf0

        chan = (status & 0x0f)
        return status if chan != (prev_status & 0x0f)

        status = (status & 0xf0)
        prev_status = (prev_status & 0xf0)

        # Both events are on the same channel. If the two status bytes are
        # exactly the same, the rest is trivial. If it's note on/note off,
        # we can combine those further.
        if status == prev_status
          data[0, 1] = [] # delete status byte from data
          status + chan
        elsif status == NOTE_OFF && data[2] == 64
          # If we see a note off and the velocity is 64, we can store
          # a note on with a velocity of 0. If the velocity isn't 64
          # then storing a note on would be bad because the would be
          # changed to 64 when reading the file back in.
          data[2] = 0 # set vel to 0; do before possible shrinking
          status = NOTE_ON + chan
          if prev_status == NOTE_ON
            data[0, 1] = [] # delete status byte
          else
            data[0] = status
          end
          status
        else
          # Can't compress data
          status + chan
        end
      end

      def accumulate_compact_report(report)
        @compact_report ||= {
          optimal: true, groups: 0, exact_groups: 0,
          original_bytes: 0, optimized_bytes: 0, tracks: []
        }
        @compact_report[:optimal] &&= report[:optimal]
        @compact_report[:groups] += report[:groups]
        @compact_report[:exact_groups] += report[:exact_groups]
        @compact_report[:original_bytes] += report[:original_bytes]
        @compact_report[:optimized_bytes] += report[:optimized_bytes]
        @compact_report[:tracks] << report
      end

      def write_instrument(instrument)
        return if instrument.nil?

        event = MetaEvent.new(META_INSTRUMENT, instrument)
        write_var_len(0)
        data = event.data_as_bytes
        @bytes_written += write_bytes(data)
      end

      def write_var_len(val)
        buffer = Utils.as_var_len(val)
        @bytes_written += write_bytes(buffer)
      end

      def write16(val)
        val = (-val | 0x8000) if val < 0

        @io.putc((val >> 8) & 0xff)
        @io.putc(val & 0xff)
        @bytes_written += 2
      end

      def write32(val)
        val = (-val | 0x80000000) if val < 0

        @io.putc((val >> 24) & 0xff)
        @io.putc((val >> 16) & 0xff)
        @io.putc((val >> 8) & 0xff)
        @io.putc(val & 0xff)
        @bytes_written += 4
      end

      def write_bytes(bytes)
        bytes.each { |b| @io.putc(b) }
        bytes.length
      end
    end
  end
end
