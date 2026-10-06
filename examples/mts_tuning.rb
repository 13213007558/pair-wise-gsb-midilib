#! /usr/bin/env ruby
#
# usage: mts_tuning.rb
#
# This script shows you how to embed a MIDI Tuning Standard bulk tuning
# dump in a MIDI file, so the file carries its own microtonal tuning
# instead of relying on per-channel pitch bend. It creates a file called
# 'mts_tuning.mid', reads it back, and verifies the tuning round-trip.

require_relative '../lib/midilib'
include MIDI

# Start from the default 128-note twelve-tone equal tempered table and
# bend a few notes.
tuning = Tuning.new(name: 'QuarterTone', program: 0)
tuning[60] = 60.5  # C4 up a quarter tone
tuning[64] = 63.99 # E4 down a cent
tuning[67] = 67.25 # G4 up a quarter tone

seq = Sequence.new
track = Track.new(seq)
seq.tracks << track

# The bulk dump is a SystemExclusive event, so it travels through the
# normal SMF read/write chain like any other event.
track.events << tuning.to_bulk_dump(device_id: SYSEX_ALL_DEVICES)

# A realtime single note change re-tunes notes that are already sounding;
# this non-realtime one only affects notes started after it.
track.events << tuning.to_single_note_change([60, 64], realtime: false)

quarter_note_length = seq.note_to_delta('quarter')
[60, 64, 67].each do |note|
  track.events << NoteOn.new(0, note, 127, 0)
  track.events << NoteOff.new(0, note, 127, quarter_note_length)
end

File.open('mts_tuning.mid', 'wb') { |file| seq.write(file) }

# Read the file back and recover the tuning table.
seq2 = Sequence.new
File.open('mts_tuning.mid', 'rb') { |file| seq2.read(file) }
seq2.tracks[0].events.each do |event|
  next unless event.is_a?(SystemExclusive)

  message = MTS.parse(event)
  case message
  when TuningBulkDump
    puts "bulk dump: program #{message.program}, name '#{message.tuning_name}'"
    puts "  note 60 -> #{message.tuning[60]}"
    puts "  note 64 -> #{message.tuning[64]}"
    puts "  note 67 -> #{message.tuning[67]}"
  when SingleNoteTuningChange
    puts "single note change (#{message.realtime? ? 'realtime' : 'non-realtime'}): #{message.changes}"
  end
end
