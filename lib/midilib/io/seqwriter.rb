# Writes MIDI files.

require_relative '../event'
require_relative '../utils'

module MIDI
  module IO
    class SeqWriter
      EXACT_GROUP_LIMIT = 6

      attr_reader :compact_report

      attr_accessor :compact

      def initialize(seq, midi_format = 1, &block) # :yields: num_tracks, index
        @seq = seq
        @midi_format = midi_format || 1
        @compact = false
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
        @compact_report = initial_compact_report if @compact
        write_header
        @update_block.call(nil, @seq.tracks.length, 0) if @update_block
        @seq.tracks.each_with_index do |track, i|
          write_track(track)
          @update_block.call(track, @seq.tracks.length, i) if @update_block
        end
        self
      end

      def write_header
        @io.print 'MThd'
        write32(6)
        write16(@midi_format) # Ignore sequence format; write as format 1 or 0, default 1
        write16(@seq.tracks.length)
        write16(@seq.ppqn)
      end

      def write_track(track)
        original_events = track.events
        optimization = nil
        track_data_bytes_written = nil

        if @compact
          optimization = compact_event_order(track,
                                              @compact_report[:tracks].length)
          track.events = optimization[:events]
        end

        @io.print 'MTrk'
        track_size_file_pos = @io.tell
        write32(0)                # Dummy byte count; overwritten later
        @bytes_written = 0        # Reset after previous write

        write_instrument(track.instrument)

        prev_status = 0
        track.events.each do |event|
          write_var_len(event.delta_time) unless event.is_a?(Realtime)

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
        track_data_bytes_written = @bytes_written
        @io.seek(track_size_file_pos)
        write32(@bytes_written)
        @io.seek(0, ::IO::SEEK_END)
      ensure
        track.events = original_events
        if optimization
          report = optimization[:report]
          report[:bytes_after] = track_data_bytes_written
          report[:bytes_saved] = report[:bytes_before] - track_data_bytes_written
          aggregate_compact_track_report(report)
        end
      end

      def initial_compact_report
        {
          compact: true,
          exact_group_limit: EXACT_GROUP_LIMIT,
          fallback_strategy: 'original order plus running-status greedy orders',
          tracks: [],
          groups: 0,
          exact_groups: 0,
          fallback_groups: 0,
          bytes_before: 0,
          bytes_after: 0,
          bytes_saved: 0,
          optimal: true
        }
      end

      def aggregate_compact_track_report(report)
        aggregate = @compact_report
        aggregate[:tracks] << report
        aggregate[:groups] += report[:groups]
        aggregate[:exact_groups] += report[:exact_groups]
        aggregate[:fallback_groups] += report[:fallback_groups]
        aggregate[:bytes_before] += report[:bytes_before]
        aggregate[:bytes_after] += report[:bytes_after]
        aggregate[:bytes_saved] += report[:bytes_saved]
        aggregate[:optimal] &&= report[:optimal]
      end

      def compact_event_order(track, track_index)
        events = track.events
        working_events = events.dup
        working_events << MetaEvent.new(META_TRACK_END) unless track_end_event?(working_events.last)

        groups = simultaneous_groups(working_events)
        group_plans = groups.map do |group|
          movable = group.reject { |event| ordering_barrier?(event) }
          if movable.empty?
            barrier_plan(group)
          else
            plans_for_group(movable, group, original_order_indices(movable))
          end
        end
        selected_path = choose_global_plan(group_plans)

        ordered_events = []
        selected_path.each do |plan|
          plan[:order].each_with_index do |event, index|
            ordered_event = event.dup
            ordered_event.delta_time = index.zero? ? plan[:delta] : 0
            ordered_events << ordered_event
          end
        end

        nontrivial_groups = groups.map { |group| group.reject { |event| ordering_barrier?(event) } }
                                          .select { |group| group.length > 1 }
        fallback_count = nontrivial_groups.count { |group| group.length > EXACT_GROUP_LIMIT }
        bytes_before = encoded_track_size(track)
        report = {
          index: track_index,
          groups: nontrivial_groups.length,
          exact_groups: nontrivial_groups.length - fallback_count,
          fallback_groups: fallback_count,
          exact_group_limit: EXACT_GROUP_LIMIT,
          fallback_strategy: 'original order plus running-status greedy orders',
          fallback_upper_bound_bytes: bytes_before,
          bytes_before: bytes_before,
          bytes_after: nil,
          bytes_saved: nil,
          optimal: fallback_count.zero?
        }

        { events: ordered_events, report: report }
      end

      def simultaneous_groups(events)
        groups = []
        group = []

        events.each do |event|
          if ordering_barrier?(event)
            groups << group unless group.empty?
            groups << [event]
            group = []
          elsif !group.empty? && event.delta_time != 0
            groups << group
            group = [event]
          else
            group << event
          end
        end
        groups << group unless group.empty?
        groups
      end

      def barrier_plan(group)
        {
          group: [],
          blockers: [],
          exact: true,
          plans: {
            0 => {
              0 => {
                cost: 0,
                order: group,
                exact: true,
                order_indices: [],
                delta: group.first.delta_time
              }
            }
          }
        }
      end

      def plans_for_group(group, segment, original_indices)
        blockers = dependency_masks(group)
        exact = group.length <= EXACT_GROUP_LIMIT
        {
          group: group,
          blockers: blockers,
          exact: exact,
          original_indices: original_indices,
          delta: first_delta(segment),
          plans: {}
        }
      end

      def original_order_indices(group)
        (0...group.length).to_a
      end

      def legal_orders(group, blockers)
        (0...group.length).to_a.permutation.select do |indices|
          selected = 0
          indices.all? do |index|
            legal = (blockers[index] & ~selected).zero?
            selected |= (1 << index)
            legal
          end
        end.map { |indices| indices.map { |index| group[index] } }
      end

      def fallback_orders(group, blockers, previous_status)
        [
          group,
          running_status_order(group, blockers),
          greedy_order(group, blockers, previous_status, true),
          greedy_order(group, blockers, previous_status, false)
        ].uniq
      end

      def running_status_order(group, blockers)
        selected = 0
        remaining = (1 << group.length) - 1
        order = []

        until remaining.zero?
          index = available_indices(group, blockers, selected, remaining).min_by do |candidate|
            event = group[candidate]
            [event.data_as_bytes[0], candidate]
          end
          order << group[index]
          selected |= (1 << index)
          remaining &= ~(1 << index)
        end

        order
      end

      def greedy_order(group, blockers, previous_status, prefer_channel_events)
        selected = 0
        remaining = (1 << group.length) - 1
        order = []

        until remaining.zero?
          index = available_indices(group, blockers, selected, remaining).min_by do |candidate|
            event = group[candidate]
            cost, next_status = encoded_event_size(event, previous_status,
                                                   order.empty? ? first_delta(group) : 0)
            channel_priority = prefer_channel_events && channel_event?(event) ? 0 : 1
            [cost, channel_priority, candidate, next_status]
          end

          event = group[index]
          _, previous_status = encoded_event_size(event, previous_status,
                                                  order.empty? ? first_delta(group) : 0)
          order << event
          selected |= (1 << index)
          remaining &= ~(1 << index)
        end

        order
      end

      def available_indices(group, blockers, selected, remaining)
        (0...group.length).select do |index|
          mask = 1 << index
          (remaining & mask).nonzero? && (blockers[index] & ~selected).zero?
        end
      end

      def transitions_for(group_plan, previous_status)
        if group_plan[:group].empty?
          transitions = {}
          group_plan[:plans][0].each do |next_status, plan|
            transitions[next_status] =
              plan.merge(cost: barrier_cost_from(plan[:order], previous_status))
          end
          return transitions
        end

        group = group_plan[:group]
        blockers = group_plan[:blockers]
        exact = group_plan[:exact]
        transitions = {}
        orders = if exact
                   legal_orders(group, blockers)
                 else
                   fallback_orders(group, blockers, previous_status)
                 end

        orders.each do |order|
          cost, next_status = simulate_order(order, previous_status, group_plan[:delta])
          order_indices = order.map { |event| group.index(event) }
          current = transitions[next_status]
          if current
            preferred_order = order_indices == group_plan[:original_indices] ? 0 : 1
            current_preferred =
              current[:order_indices] == group_plan[:original_indices] ? 0 : 1
            next if current[:cost] < cost ||
                    (current[:cost] == cost &&
                         (current_preferred < preferred_order ||
                          ((current_preferred == preferred_order) &&
                           lexicographic?(current[:order_indices], order_indices))))
          end

          transitions[next_status] = {
            cost: cost,
            order: order,
            order_indices: order_indices,
            exact: exact,
            delta: group_plan[:delta]
          }
        end

        transitions
      end

      def barrier_cost_from(order, previous_status)
        order.sum(0) do |event|
          cost, previous_status = encoded_event_size(event, previous_status, event.delta_time)
          cost
        end
      end

      def choose_global_plan(group_plans)
        states = { 0 => { cost: 0, original: true, path: [] } }

        group_plans.each do |group_plan|
          next_states = {}

          states.each do |previous_status, state|
            group_plan[:plans][previous_status] ||=
              transitions_for(group_plan, previous_status)
            group_plan[:plans][previous_status].each do |next_status, plan|
              candidate_cost = state[:cost] + plan[:cost]
              current = next_states[next_status]
              candidate_path = state[:path] + [plan]
              candidate_original =
                state[:original] && plan[:order_indices] == original_indices_for(group_plan)
              if current
                next if current[:cost] < candidate_cost ||
                        (current[:cost] == candidate_cost &&
                         (((current[:original] == true) && (candidate_original == false)) ||
                          ((current[:original] == candidate_original) &&
                           lexicographic?(path_identity(current[:path]),
                                         path_identity(candidate_path)))))
              end

              next_states[next_status] = {
                cost: candidate_cost,
                original: candidate_original,
                path: candidate_path
              }
            end
          end

          states = next_states
        end

        states.values.min_by { |state| state[:cost] }[:path]
      end

      def path_identity(path)
        path.flat_map { |plan| plan[:order_indices] }
      end

      def original_indices_for(group_plan)
        (0...group_plan[:group].length).to_a
      end

      def lexicographic?(first, second)
        first.zip(second).each do |left, right|
          return true if right.nil?
          return false if left.nil?
          return true if left < right
          return false if left > right
        end
        true
      end

      def dependency_masks(group)
        masks = Array.new(group.length, 0)

        group.each_with_index do |later, later_index|
          group[0...later_index].each_with_index do |earlier, earlier_index|
            next unless preserve_relative_order?(earlier, later)

            masks[later_index] |= (1 << earlier_index)
          end
        end

        masks
      end

      def preserve_relative_order?(first, second)
        return false unless channel_event?(first) && channel_event?(second)
        return false unless first.channel == second.channel
        return true if channel_state_event?(first) || channel_state_event?(second)

        note_event?(first) && note_event?(second) && first.note == second.note
      end

      def channel_event?(event)
        event.status < 0xf0
      end

      def channel_state_event?(event)
        event.is_a?(Controller) || event.is_a?(ProgramChange) ||
          event.is_a?(PitchBend) || event.is_a?(ChannelPressure)
      end

      def note_event?(event)
        event.is_a?(NoteEvent)
      end

      def ordering_barrier?(event)
        !channel_event?(event)
      end

      def track_end_event?(event)
        event.is_a?(MetaEvent) && event.meta_type == META_TRACK_END
      end

      def first_delta(group)
        event = group.first
        event.is_a?(Realtime) ? 0 : event.delta_time
      end

      def simulate_order(order, previous_status, delta)
        total_cost = 0
        order.each_with_index do |event, index|
          event_delta = index.zero? ? delta : 0
          cost, previous_status = encoded_event_size(event, previous_status, event_delta)
          total_cost += cost
        end
        [total_cost, previous_status]
      end

      def encoded_track_size(track)
        events = track.events.dup
        events << MetaEvent.new(META_TRACK_END) unless track_end_event?(events.last)

        previous_status = 0
        total_cost = 0
        if track.instrument
          event = MetaEvent.new(META_INSTRUMENT, track.instrument)
          cost, previous_status = encoded_event_size(event, previous_status, 0)
          total_cost += cost
        end

        events.each do |event|
          cost, previous_status = encoded_event_size(event, previous_status, event.delta_time)
          total_cost += cost
        end
        total_cost
      end

      def encoded_event_size(event, previous_status, delta_time)
        data = event.data_as_bytes.dup
        next_status = possibly_munge_due_to_running_status_byte(data, previous_status)
        delta_cost = event.is_a?(Realtime) ? 0 : Utils.as_var_len(delta_time).length
        [delta_cost + data.length, next_status]
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
