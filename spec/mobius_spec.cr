require "spec"
require "../src/mobius/index"

describe Mobius::Pattern do
  it "canonicalizes ignored positions while preserving the target distance" do
    pattern = Mobius::Pattern.parse("**a*b**")
    pattern.symbols.should eq([97_u8, nil, 98_u8])
    pattern.trailing_skips.should eq(2)
    pattern.distance_from_last_literal(3).should eq(5)
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
end
