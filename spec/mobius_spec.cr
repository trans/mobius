require "spec"
require "../src/mobius/index"

# Scans every anchor using the patterns as typed. The context ends at the
# anchor; the event starts `distance` later. Support requires the event's last
# literal to lie inside the corpus.
def direct_cooccur(corpus : Bytes, context : String, event : String, distance : Int32) : Tuple(Int64, Int64)
  support = 0_i64
  joint = 0_i64
  (-context.size).upto(corpus.size + context.size) do |anchor|
    context_start = anchor - context.size + 1
    in_context = context.each_char.with_index.all? do |char, slot|
      position = context_start + slot
      char == '*' || (position >= 0 && position < corpus.size && corpus[position] == char.ord)
    end
    next unless in_context
    event_start = anchor + distance
    literals = event.each_char.with_index.reject { |char, _| char == '*' }.to_a
    next unless literals.all? { |_, slot| event_start + slot < corpus.size }
    support += 1
    joint += 1 if literals.all? { |char, slot| corpus[event_start + slot] == char.ord }
  end
  {support, joint}
end

describe Mobius::Pattern do
  it "canonicalizes ignored positions while preserving the target distance" do
    pattern = Mobius::Pattern.parse("**a*b**")
    pattern.symbols.should eq([97_u8, nil, 98_u8])
    pattern.trailing_skips.should eq(2)
    pattern.distance_from_last_literal(3).should eq(5)
  end

  it "records leading ignored positions for use as an event offset" do
    Mobius::Pattern.parse("**a*b**").leading_skips.should eq(2)
    Mobius::Pattern.parse("a").leading_skips.should eq(0)
  end

  it "allows a literal skip marker and escaped control bytes" do
    pattern = Mobius::Pattern.parse("\\*\\n")
    pattern.symbols.should eq([42_u8, 10_u8])
  end

  it "rejects a pattern made only of ignored positions" do
    expect_raises(ArgumentError) { Mobius::Pattern.parse("****") }
  end
end

describe Mobius::Index do
  it "answers skipped pattern and horizon counts exactly" do
    index = Mobius::Index.from_bytes("banana".to_slice.dup)
    pattern = Mobius::Pattern.parse("a*a")
    matches = index.matching_end_positions(pattern)
    matches.should eq([3, 5])
    next_byte = index.query(pattern, 1)
    next_byte.support.should eq(1)
    next_byte.counts['n'.ord].should eq(1)
    two_ahead = index.query(pattern, 2)
    two_ahead.support.should eq(1)
    two_ahead.counts['a'.ord].should eq(1)
  end

  it "matches a direct scan for every four-slot mask across several horizons" do
    corpus = "abacaba.bacaabacaba.baca".to_slice.dup
    index = Mobius::Index.from_bytes(corpus)
    1.upto(15) do |mask|
      text = String.build do |io|
        4.times do |slot|
          io << ((mask & (1 << slot)) == 0 ? '*' : "abac"[slot])
        end
      end
      pattern = Mobius::Pattern.parse(text)
      1.upto(7) do |distance|
        actual = index.query(pattern, distance)
        expected = Array(Int64).new(256, 0_i64)
        effective = pattern.distance_from_last_literal(distance)
        0.upto(corpus.size - effective - 1) do |endpoint|
          start = endpoint - pattern.span + 1
          next if start < 0
          matches = pattern.symbols.each_with_index.all? do |symbol, slot|
            symbol.nil? || corpus[start + slot] == symbol
          end
          expected[corpus[endpoint + effective].to_i] += 1 if matches
        end
        actual.counts.should eq(expected)
      end
    end
  end

  it "matches across 64-bit word boundaries and at distant offsets" do
    corpus = ("abca.cab" * 40).to_slice.dup
    index = Mobius::Index.from_bytes(corpus)
    pattern = Mobius::Pattern.parse("a***.cab")
    1.upto(70) do |distance|
      actual = index.query(pattern, distance)
      expected = Array(Int64).new(256, 0_i64)
      effective = pattern.distance_from_last_literal(distance)
      0.upto(corpus.size - effective - 1) do |endpoint|
        start = endpoint - pattern.span + 1
        next if start < 0
        matches = pattern.symbols.each_with_index.all? do |symbol, slot|
          symbol.nil? || corpus[start + slot] == symbol
        end
        expected[corpus[endpoint + effective].to_i] += 1 if matches
      end
      actual.counts.should eq(expected)
    end
  end

  it "round trips the compact index" do
    index = Mobius::Index.from_bytes("a*ba\naba".to_slice.dup)
    File.tempfile(".midx") do |file|
      index.save(file.path)
      restored = Mobius::Index.load(file.path)
      restored.corpus_size.should eq(index.corpus_size)
      restored.alphabet.should eq(index.alphabet)
      pattern = Mobius::Pattern.parse("a*b")
      restored.query(pattern, 2).counts.should eq(index.query(pattern, 2).counts)
    end
  end

  it "separates joint continuations that single-offset marginals cannot" do
    index = Mobius::Index.from_bytes("Xab.Xba.Yaa.Ybb.".to_slice.dup)
    x = Mobius::Pattern.parse("X")
    y = Mobius::Pattern.parse("Y")
    1.upto(2) { |distance| index.query(x, distance).counts.should eq(index.query(y, distance).counts) }

    {"ab" => {1, 0}, "ba" => {1, 0}, "aa" => {0, 1}, "bb" => {0, 1}}.each do |block, (after_x, after_y)|
      event = Mobius::Pattern.parse(block)
      index.cooccur(x, event, 1).joint.should eq(after_x)
      index.cooccur(y, event, 1).joint.should eq(after_y)
    end
    index.events(x, 1, 2).counts.should eq({"ab".to_slice => 1_i64, "ba".to_slice => 1_i64})
    index.events(y, 1, 2).counts.should eq({"aa".to_slice => 1_i64, "bb".to_slice => 1_i64})
  end

  it "reproduces the target histogram for one-byte events" do
    corpus = "abacaba.bacaabacaba.baca".to_slice.dup
    index = Mobius::Index.from_bytes(corpus)
    {"a*a", "ba", "c**", "*b*c"}.each do |text|
      pattern = Mobius::Pattern.parse(text)
      1.upto(8) do |distance|
        histogram = index.query(pattern, distance)
        "abc.".each_char do |target|
          result = index.cooccur(pattern, Mobius::Pattern.parse(target.to_s), distance)
          result.support.should eq(histogram.support)
          result.joint.should eq(histogram.counts[target.ord])
        end
      end
    end
  end

  it "matches a direct scan for masked contexts and masked events" do
    corpus = ("abacaba.bacaabacaba.baca" * 3).to_slice.dup
    index = Mobius::Index.from_bytes(corpus)
    {"a*a", "*ba*", "c", "ab**"}.each do |context|
      {"a", "ab", "a*a", "*b", "ba*", "**c", ".b*c"}.each do |event|
        1.upto(9) do |distance|
          result = index.cooccur(Mobius::Pattern.parse(context), Mobius::Pattern.parse(event), distance)
          {result.support, result.joint}.should eq(direct_cooccur(corpus, context, event, distance))
        end
      end
    end
  end

  it "tallies observed blocks consistently with cooccur" do
    corpus = ("abca.cab" * 40).to_slice.dup
    index = Mobius::Index.from_bytes(corpus)
    context = Mobius::Pattern.parse("a*.c")
    {1, 3, 70}.each do |distance|
      1.upto(4) do |length|
        result = index.events(context, distance, length)
        result.counts.values.sum.should eq(result.support)
        result.counts.each do |block, count|
          joint = index.cooccur(context, Mobius::Pattern.parse(String.new(block)), distance)
          joint.support.should eq(result.support)
          joint.joint.should eq(count)
        end
      end
    end
  end
end
