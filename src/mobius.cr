require "./mobius/index"

module Mobius
  USAGE = <<-TEXT
  Usage:
    mobius build <corpus.txt> <index.midx>
    mobius query <index.midx> <pattern> <distance>
    mobius profile <index.midx> <pattern> <max-distance> [min-distance]

  Pattern syntax: * ignores one byte; \\* matches a literal *, and
  \\n, \\r, \\t, \\xHH encode literal bytes. Distance 1 is the next byte.
  A pattern may span up to 16 positions, including ignored positions.
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
