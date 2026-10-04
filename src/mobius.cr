require "./mobius/index"
require "./mobius/kneser_ney"

module Mobius
  USAGE = <<-TEXT
  Usage:
    mobius build <corpus.txt> <index.midx>
    mobius query <index.midx> <pattern> <distance>
    mobius profile <index.midx> <pattern> <max-distance> [min-distance]
    mobius cooccur <index.midx> <context> <event> <distance>
    mobius events <index.midx> <context> <length> <distance> [limit]
    mobius baseline <corpus.txt> [max-context]
    mobius predict <corpus.txt> <context> <context-limit> [candidates]

  Pattern syntax: * ignores one byte; \\* matches a literal *, and
  \\n, \\r, \\t, \\xHH encode literal bytes. Distance 1 is the next byte.
  A pattern may span up to 16 positions, including ignored positions.
  An event pattern starts at the given distance after the context; its
  leading * positions delay its first literal. `events` lists the observed
  contiguous blocks of the given length at that distance.

  `baseline` holds out the last 10% of the corpus. It chooses the Kneser–Ney
  context limit (0 to max-context, default 16) on the last 10% of the rest,
  then reports bits per byte on the held-out text. `predict` shows the
  evidence for one context, with counts from the first 90%.
  TEXT

  def self.display_byte(byte : UInt8) : String
    case byte
    when 10_u8 then "\\n"
    when 13_u8 then "\\r"
    when  9_u8 then "\\t"
    when 32_u8 then "<space>"
    else
      if byte >= 33_u8 && byte <= 126_u8
        byte.chr.to_s
      else
        "\\x#{byte.to_s(16).rjust(2, '0')}"
      end
    end
  end

  def self.display_bytes(bytes : Bytes) : String
    String.build do |io|
      io << '"'
      bytes.each do |byte|
        case byte
        when 10_u8 then io << "\\n"
        when 13_u8 then io << "\\r"
        when  9_u8 then io << "\\t"
        when 34_u8 then io << "\\\""
        when 92_u8 then io << "\\\\"
        else
          if byte >= 32_u8 && byte <= 126_u8
            io << byte.chr
          else
            io << "\\x" << byte.to_s(16).rjust(2, '0')
          end
        end
      end
      io << '"'
    end
  end

  # nanoGPT's split: the first 90% is training text.
  def self.training_end(size : Int32) : Int32
    (size.to_i64 * 9 // 10).to_i32
  end

  def self.literal_bytes(text : String) : Bytes
    pattern = Pattern.parse(text, Int32::MAX)
    unless pattern.leading_skips == 0 && pattern.trailing_skips == 0 && pattern.symbols.all?
      raise ArgumentError.new("context must be literal; write \\* for an asterisk")
    end
    Bytes.new(pattern.symbols.size) { |i| pattern.symbols[i].not_nil! }
  end

  def self.parse_positive(text : String) : Int32
    value = text.to_i?
    raise ArgumentError.new("expected a positive integer, got #{text.inspect}") unless value && value > 0
    value
  end

  def self.run(args : Array(String)) : Nil
    command = args.shift?
    case command
    when "build"
      raise ArgumentError.new(USAGE) unless args.size == 2
      index = Index.from_file(args[0])
      index.save(args[1])
      puts "corpus_bytes=#{index.corpus_size} alphabet=#{index.alphabet.size} bitplane_bytes=#{index.bitplane_bytes} index=#{args[1]}"
    when "query"
      raise ArgumentError.new(USAGE) unless args.size == 3
      index = Index.load(args[0])
      pattern = Pattern.parse(args[1])
      distance = parse_positive(args[2])
      result = index.query(pattern, distance)
      puts "pattern=#{args[1].inspect} span=#{pattern.span} distance=#{distance} effective_distance=#{pattern.distance_from_last_literal(distance)}"
      puts "support=#{result.support} entropy_bits=#{result.entropy_bits.round(6)}"
      puts "target\tcount\tprobability"
      result.most_common.each do |byte, count|
        probability = count.to_f / result.support
        puts "#{display_byte(byte)}\t#{count}\t#{probability.round(6)}"
      end
    when "profile"
      raise ArgumentError.new(USAGE) unless args.size == 3 || args.size == 4
      index = Index.load(args[0])
      pattern = Pattern.parse(args[1])
      max_distance = parse_positive(args[2])
      min_distance = args.size == 4 ? parse_positive(args[3]) : 1
      raise ArgumentError.new("minimum distance exceeds maximum distance") if min_distance > max_distance
      positions = index.matching_end_positions(pattern)
      puts "pattern=#{args[1].inspect} matches=#{positions.size} span=#{pattern.span} trailing_skips=#{pattern.trailing_skips}"
      puts "distance\tsupport\tentropy_bits\tdrop_from_previous_bits\ttop_target\ttop_probability"
      previous_entropy = nil.as(Float64?)
      (min_distance..max_distance).each do |distance|
        result = index.histogram(positions, pattern.distance_from_last_literal(distance))
        if result.support == 0
          puts "#{distance}\t0\tNA\tNA\tNA\tNA"
          previous_entropy = nil
          next
        end
        entropy = result.entropy_bits
        drop = previous_entropy ? (previous_entropy - entropy).round(6).to_s : "NA"
        top = result.most_common(1).first
        puts "#{distance}\t#{result.support}\t#{entropy.round(6)}\t#{drop}\t#{display_byte(top[0])}\t#{(top[1].to_f / result.support).round(6)}"
        previous_entropy = entropy
      end
    when "cooccur"
      raise ArgumentError.new(USAGE) unless args.size == 4
      index = Index.load(args[0])
      context = Pattern.parse(args[1])
      event = Pattern.parse(args[2])
      distance = parse_positive(args[3])
      result = index.cooccur(context, event, distance)
      offset = context.distance_from_last_literal(distance).to_i64 + event.leading_skips
      puts "context=#{args[1].inspect} event=#{args[2].inspect} distance=#{distance} event_offset=#{offset}"
      puts "support=#{result.support} joint=#{result.joint} probability=#{result.probability.round(6)}"
    when "events"
      raise ArgumentError.new(USAGE) unless args.size == 4 || args.size == 5
      index = Index.load(args[0])
      context = Pattern.parse(args[1])
      length = parse_positive(args[2])
      distance = parse_positive(args[3])
      limit = args.size == 5 ? parse_positive(args[4]) : 20
      result = index.events(context, distance, length)
      puts "context=#{args[1].inspect} length=#{length} distance=#{distance} effective_distance=#{context.distance_from_last_literal(distance)}"
      puts "support=#{result.support} distinct=#{result.counts.size}"
      puts "event\tcount\tprobability"
      result.most_common(limit).each do |bytes, count|
        puts "#{display_bytes(bytes)}\t#{count}\t#{(count.to_f / result.support).round(6)}"
      end
    when "baseline"
      raise ArgumentError.new(USAGE) unless args.size == 1 || args.size == 2
      corpus = File.read(args[0]).to_slice
      max_context = args.size == 2 ? parse_positive(args[1]) : 16
      test_start = training_end(corpus.size)
      dev_start = training_end(test_start)
      puts "corpus_bytes=#{corpus.size} training=[0,#{test_start}) test=[#{test_start},#{corpus.size})"
      puts "choosing the context limit: counts from [0,#{dev_start}), scored on [#{dev_start},#{test_start})"
      dev = KneserNey.new(SuffixArray.new(corpus[0, dev_start]), max_context).bits_per_byte(corpus, dev_start, test_start)
      puts "context_limit\tdev_bits_per_byte"
      dev.each_with_index { |bits, limit| puts "#{limit}\t#{bits.round(4)}" }
      best = (0..max_context).min_by { |limit| dev[limit] }
      model = KneserNey.new(SuffixArray.new(corpus[0, test_start]), best)
      bits = model.bits_per_byte(corpus, test_start, corpus.size)[best]
      puts "chosen_context_limit=#{best}"
      puts "test_bits_per_byte=#{bits.round(4)} test_nats_per_byte=#{(bits * Math.log(2.0)).round(4)}"
    when "predict"
      raise ArgumentError.new(USAGE) unless args.size == 3 || args.size == 4
      corpus = File.read(args[0]).to_slice
      context = literal_bytes(args[1])
      limit = parse_positive(args[2])
      shown = args.size == 4 ? parse_positive(args[3]) : 10
      counts_end = training_end(corpus.size)
      model = KneserNey.new(SuffixArray.new(corpus[0, counts_end]), limit)
      levels = model.levels(context)
      ranked = (0..255).map { |byte| {byte.to_u8, model.probabilities(levels, byte.to_u8)[limit]} }
      ranked.sort_by! { |entry| -entry[1] }
      top = ranked.first[0]
      puts "context=#{args[1].inspect} context_limit=#{limit} counts_from=[0,#{counts_end})"
      puts "note: the context is shorter than the limit, so every level uses continuation counts" if context.size < limit
      puts "length\tcontext\toccurrences\tdistinct_next\tcounts_used\tbackoff_weight\tp(#{display_byte(top)})_after"
      lower = 1.0 / KneserNey::VOCABULARY
      levels.each do |level|
        k = level.context_length
        raw = k == limit
        lower = raw ? level.raw_term(top) + level.raw_backoff * lower : level.continuation_term(top) + level.continuation_backoff * lower
        backoff = raw ? level.raw_backoff : level.continuation_backoff
        puts "#{k}\t#{display_bytes(context[context.size - k, k])}\t#{level.raw_total}\t#{level.bytes.size}\t#{raw ? "raw" : "continuation"}\t#{backoff.round(6)}\t#{lower.round(6)}"
      end
      puts "next\tprobability\tcount_after_longest_seen_context"
      ranked.first(shown).each do |byte, probability|
        puts "#{display_byte(byte)}\t#{probability.round(6)}\t#{levels.last.raw_count(byte)}"
      end
    when "help", "--help", "-h"
      puts USAGE
    else
      raise ArgumentError.new(USAGE)
    end
  rescue ex : ArgumentError
    STDERR.puts "Error: #{ex.message}"
    exit 1
  end
end

Mobius.run(ARGV)
