require "./mobius/index"
require "./mobius/kneser_ney"
require "./mobius/interactions"
require "./mobius/residual"
require "./mobius/recency"
require "./mobius/lattice"
require "./mobius/sufficiency"

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
    mobius interactions <corpus.txt> [window=16] [order=3] [support=10]
                        [limit=6] [keep=100000] [stride=10]
    mobius residual <corpus.txt> [window=16] [order=3] [support=10]
                    [limit=6] [keep=100000] [folds=10] [interleave=0] [stride=1]
    mobius recency <corpus.txt> [limit=6] [context=7] [spans=500,2000,10000,50000]
    mobius lattice <corpus.txt> [window=16] [k=1,4,16,64] [support=2,5,10,25] [stride=20]
    mobius neighbors <corpus.txt> <context> [window=16] [k=16] [support=2]
    mobius sufficiency <corpus.txt> [window=16] [support=2,10] [prior=0.5,2,8] [discount=D,...] [chain=C,...]
                       [nearest=P,...] [stride=100] [offset=0] [suffixes] [hierarchical] [test]
    mobius sufficient <corpus.txt> <context> [window=16] [support=2] [prior=2] [discount=D] [chain=C]
                      [nearest=P] [suffixes] [hierarchical]

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

  `interactions` mines patterns of up to `order` positions in the last
  `window` bytes that reach beyond the Kneser–Ney context `limit`, keeps the
  `keep` best by bits saved over their parents, and adds the Möbius terms of
  matching patterns to Kneser–Ney. It chooses how many patterns to use on the
  development text, then scores every `stride`-th held-out byte.

  `residual` instead scores each pattern by what Kneser–Ney gets wrong at its
  training matches, using Kneser–Ney cross-fitted over `folds` folds
  (contiguous, or blocks of `interleave` bytes dealt in turn), and
  multiplies Kneser–Ney by the matching patterns' correction ratios. It
  compares using every matching pattern with using only the best-ranked one.

  `recency` mixes Kneser–Ney with a cache of what followed each recent context
  (up to `context` bytes) within the last `span` bytes. The mixing weight
  depends on the longest context the cache has seen; weights and span are
  fitted on the development text, then applied unchanged to the test text.

  `lattice` predicts from the masked patterns consistent with the last
  `window` bytes, using exact counts from a bit-plane index over the training
  text: each pattern's Witten–Bell estimate, weighted by how well it predicts
  its own matches when each is left out, averaged over the `k` heaviest
  patterns with at least `support` matches. It chooses `k` and `support` on
  every `stride`-th development byte and scores the test text the same way,
  with Kneser–Ney on the same bytes for reference. `neighbors` shows the kept
  patterns for one context, with counts from the first 90%.

  `sufficiency` weights each pattern by the posterior probability that
  refinement stops there: from the empty pattern outward, a pattern passes its
  weight to a refinement when matches that agree with the history at the
  added offset continue differently from those that disagree. `prior` is the
  Dirichlet concentration of every estimate (pseudo-counts toward the byte
  frequencies). It chooses `support` and `prior` on the development text and
  scores the test text the same way. `sufficient` shows the weights for one
  context. With `suffixes`, patterns may only grow by the next older offset,
  so only contiguous suffixes are used. With `hierarchical`, each pattern's
  prior is centered on its parent's estimate (the pattern without its farthest
  offset) instead of on the byte frequencies. With `discount`, estimates are
  Pitman–Yor (discount D, strength `prior`) instead of Dirichlet; `prior=0`
  gives interpolated absolute discounting. With `chain` (and `hierarchical`),
  parents are estimated from continuation counts, as in Kneser–Ney, at that
  strength. With `nearest`, refining favors the nearest unfixed offset with
  that probability (1 gives the suffix model). Every `stride`-th byte is
  scored, starting `offset` bytes in. Scores include the paired
  standard error of the difference from Kneser–Ney and the mean number of
  positions in the patterns the weight lands on. The test text is scored
  only when `test` is given.
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

  def self.interactions(args : Array(String)) : Nil
    raise ArgumentError.new(USAGE) if args.empty?
    corpus = File.read(args.shift).to_slice
    options = {"window" => 16, "order" => 3, "support" => 10, "limit" => 6, "keep" => 100_000, "stride" => 10}
    args.each do |arg|
      name, _, value = arg.partition('=')
      raise ArgumentError.new("unknown option #{name.inspect}") unless options.has_key?(name)
      options[name] = value.to_i? || raise ArgumentError.new("option #{name} needs an integer")
    end
    keep = options["keep"]
    test_start = training_end(corpus.size)
    dev_start = training_end(test_start)
    started = Time.instant
    model = InteractionModel.new(corpus[0, dev_start], options["window"], options["order"], options["support"], options["limit"], keep)
    puts "options: #{options.map { |name, value| "#{name}=#{value}" }.join(' ')}"
    puts "mined on [0,#{dev_start}): candidates=#{model.candidates} kept=#{model.ranked.size} seconds=#{(Time.instant - started).total_seconds.round(1)}"
    puts "rank\tpattern\tsupport\tscore_bits\ttop_next"
    model.ranked.first(20).each_with_index do |pattern, rank|
      top = pattern.counts.each_with_index.to_a.sort_by { |count, slot| {-count, slot} }.first(3)
      next_text = top.map { |count, slot| "#{display_byte(model.alphabet[slot])}:#{(count / pattern.support).round(2)}" }.join(' ')
      puts "#{rank + 1}\t\"#{model.display(pattern.shape, pattern.key)}\"\t#{pattern.support}\t#{pattern.score.round(1)}\t#{next_text}"
    end
    actives = ([0, 100, 1_000, 10_000, 100_000].select { |count| count < model.ranked.size } << model.ranked.size).uniq
    evaluate = ->(scoring : InteractionModel, start : Int32, finish : Int32, counts : Array(Int32)) do
      bits = Array(Float64).new(counts.size, 0.0)
      matched = Array(Int64).new(counts.size, 0_i64)
      positions = (start...finish).step(options["stride"]).to_a
      positions.each do |position|
        base = scoring.base_scores(corpus, position)
        counts.each_with_index do |active, i|
          scores = scoring.log_scores(corpus, position, active, base)
          bits[i] -= Math.log2(scoring.probability(scores, corpus[position]))
          matched[i] += scoring.matching(corpus, position, active).size
        end
      end
      {bits.map { |sum| sum / positions.size }, matched.map { |sum| sum / positions.size }, positions.size}
    end
    started = Time.instant
    dev_bits, dev_matched, sampled = evaluate.call(model, dev_start, test_start, actives)
    puts "development: every #{options["stride"]}th byte of [#{dev_start},#{test_start}), #{sampled} bytes, seconds=#{(Time.instant - started).total_seconds.round(1)}"
    puts "patterns\tmatched_per_byte\tbits_per_byte\tchange_vs_kneser_ney"
    actives.each_with_index do |active, i|
      puts "#{active}\t#{dev_matched[i].round(1)}\t#{dev_bits[i].round(4)}\t#{(dev_bits[i] - dev_bits[0]).round(4)}"
    end
    best = actives[(0...actives.size).min_by { |i| dev_bits[i] }]
    final = InteractionModel.new(corpus[0, test_start], options["window"], options["order"], options["support"], options["limit"], Math.max(best, 1))
    test_bits, test_matched, sampled = evaluate.call(final, test_start, corpus.size, [0, best].uniq)
    puts "test: every #{options["stride"]}th byte of [#{test_start},#{corpus.size}), #{sampled} bytes, mined on [0,#{test_start})"
    puts "kneser_ney_bits_per_byte=#{test_bits[0].round(4)}"
    puts "with_#{best}_patterns_bits_per_byte=#{test_bits.last.round(4)} change=#{(test_bits.last - test_bits[0]).round(4)} matched_per_byte=#{test_matched.last.round(1)}"
  end

  def self.residual(args : Array(String)) : Nil
    raise ArgumentError.new(USAGE) if args.empty?
    corpus = File.read(args.shift).to_slice
    options = {"window" => 16, "order" => 3, "support" => 10, "limit" => 6, "keep" => 100_000, "folds" => 10, "interleave" => 0, "stride" => 1}
    args.each do |arg|
      name, _, value = arg.partition('=')
      raise ArgumentError.new("unknown option #{name.inspect}") unless options.has_key?(name)
      options[name] = value.to_i? || raise ArgumentError.new("option #{name} needs an integer")
    end
    test_start = training_end(corpus.size)
    dev_start = training_end(test_start)
    build = ->(text : Bytes, keep : Int32) do
      ResidualModel.new(text, options["window"], options["order"], options["support"], options["limit"], options["folds"], options["interleave"], keep)
    end
    # Mean bits per byte for each pattern count, using all matches and the best one.
    evaluate = ->(model : ResidualModel, start : Int32, finish : Int32, counts : Array(Int32)) do
      every = Array(Float64).new(counts.size, 0.0)
      single = Array(Float64).new(counts.size, 0.0)
      matched = Array(Float64).new(counts.size, 0.0)
      positions = (start...finish).step(options["stride"]).to_a
      positions.each do |position|
        base = model.base_scores(corpus, position)
        ranks = model.matching(corpus, position, counts.max)
        counts.each_with_index do |active, i|
          used = ranks.select { |rank| rank < active }
          every[i] -= Math.log2(model.probability(model.log_scores(used, false, base), corpus[position]))
          single[i] -= Math.log2(model.probability(model.log_scores(used, true, base), corpus[position]))
          matched[i] += used.size
        end
      end
      {every.map { |sum| sum / positions.size }, single.map { |sum| sum / positions.size }, matched.map { |sum| sum / positions.size }, positions.size}
    end

    started = Time.instant
    model = build.call(corpus[0, dev_start], options["keep"])
    puts "options: #{options.map { |name, value| "#{name}=#{value}" }.join(' ')}"
    puts "mined on [0,#{dev_start}): candidates=#{model.candidates} kept=#{model.ranked.size} seconds=#{(Time.instant - started).total_seconds.round(1)}"
    puts "rank\tpattern\tsupport\tscore_bits\tlargest_corrections"
    model.ranked.first(25).each_with_index do |pattern, rank|
      slots = (0...model.alphabet.size).to_a.sort_by { |slot| -pattern.log_ratios[slot].abs }.first(3)
      corrections = slots.map { |slot| "#{display_byte(model.alphabet[slot])}×#{Math.exp(pattern.log_ratios[slot]).round(2)}" }.join(' ')
      puts "#{rank + 1}\t\"#{model.display(pattern.shape, pattern.key)}\"\t#{pattern.support}\t#{pattern.score.round(1)}\t#{corrections}"
    end
    actives = ([0, 10, 100, 1_000, 10_000, 100_000].select { |count| count < model.ranked.size } << model.ranked.size).uniq
    started = Time.instant
    every, single, matched, sampled = evaluate.call(model, dev_start, test_start, actives)
    puts "development: every #{options["stride"]}th byte of [#{dev_start},#{test_start}), #{sampled} bytes, seconds=#{(Time.instant - started).total_seconds.round(1)}"
    puts "patterns\tmatched_per_byte\tall_matches_bits\tchange\tbest_match_bits\tchange"
    actives.each_with_index do |active, i|
      puts "#{active}\t#{matched[i].round(1)}\t#{every[i].round(4)}\t#{(every[i] - every[0]).round(4)}\t#{single[i].round(4)}\t#{(single[i] - single[0]).round(4)}"
    end
    choices = actives.each_index.flat_map { |i| [{every[i], actives[i], false}, {single[i], actives[i], true}] }
    _, chosen, best_only = choices.min_by { |choice| {choice[0], choice[1]} }
    rule = best_only ? "best match" : "all matches"
    final = build.call(corpus[0, test_start], Math.max(chosen, 1))
    every, single, matched, sampled = evaluate.call(final, test_start, corpus.size, [0, chosen].uniq)
    result = best_only ? single.last : every.last
    puts "test: every #{options["stride"]}th byte of [#{test_start},#{corpus.size}), #{sampled} bytes, mined on [0,#{test_start}), #{chosen} patterns, #{rule}"
    puts "kneser_ney_bits_per_byte=#{every[0].round(4)}"
    puts "with_patterns_bits_per_byte=#{result.round(4)} change=#{(result - every[0]).round(4)} matched_per_byte=#{matched.last.round(1)}"
  end

  def self.recency(args : Array(String)) : Nil
    raise ArgumentError.new(USAGE) if args.empty?
    corpus = File.read(args.shift).to_slice
    options = {"limit" => 6, "context" => 7}
    spans = [500, 2_000, 10_000, 50_000]
    args.each do |arg|
      name, _, value = arg.partition('=')
      if name == "spans"
        spans = value.split(',').map { |span| parse_positive(span) }
      elsif options.has_key?(name)
        options[name] = value.to_i? || raise ArgumentError.new("option #{name} needs an integer")
      else
        raise ArgumentError.new("unknown option #{name.inspect}")
      end
    end
    limit = options["limit"]
    context = options["context"]
    buckets = context + 2
    test_start = training_end(corpus.size)
    dev_start = training_end(test_start)
    # Each actual byte's probability under Kneser–Ney, and under the cache with
    # its bucket (longest cached context + 1).
    kneser_ney_for = ->(counts_end : Int32, start : Int32, finish : Int32) do
      model = KneserNey.new(SuffixArray.new(corpus[0, counts_end]), limit)
      (start...finish).map { |position| model.probability(corpus[0, position], corpus[position], limit) }
    end
    cache_for = ->(span : Int32, start : Int32, finish : Int32) do
      cache = RecencyCache.new(corpus, span, context, start)
      probabilities = [] of Float64
      levels = [] of Int32
      (start...finish).each do |position|
        cache.advance(position)
        probabilities << cache.probability(corpus[position])
        levels << cache.longest + 1
      end
      {probabilities, levels}
    end
    mixed_bits = ->(kneser_ney : Array(Float64), cache : Array(Float64), levels : Array(Int32), weights : Array(Float64)) do
      kneser_ney.each_index.sum { |i| -Math.log2(RecencyMixture.probability(kneser_ney[i], cache[i], weights[levels[i]])) } / kneser_ney.size
    end

    dev_kneser_ney = kneser_ney_for.call(dev_start, dev_start, test_start)
    base_bits = dev_kneser_ney.sum { |p| -Math.log2(p) } / dev_kneser_ney.size
    puts "options: limit=#{limit} context=#{context} spans=#{spans.join(',')}"
    puts "development: [#{dev_start},#{test_start}), Kneser–Ney counts from [0,#{dev_start}), kneser_ney_bits_per_byte=#{base_bits.round(4)}"
    puts "span\tbits_per_byte\tchange_vs_kneser_ney"
    fitted = spans.map do |span|
      cache, levels = cache_for.call(span, dev_start, test_start)
      weights = RecencyMixture.fit(dev_kneser_ney, cache, levels, buckets)
      bits = mixed_bits.call(dev_kneser_ney, cache, levels, weights)
      puts "#{span}\t#{bits.round(4)}\t#{(bits - base_bits).round(4)}"
      {span, weights, bits, cache, levels}
    end
    span, weights, _, cache, levels = fitted.min_by { |entry| entry[2] }
    puts "chosen_span=#{span}"
    puts "longest_cached_context\tdevelopment_bytes\tcache_weight"
    buckets.times do |bucket|
      puts "#{bucket - 1}\t#{levels.count(bucket)}\t#{weights[bucket].round(3)}"
    end
    puts "largest development gains (one per context and byte):"
    puts "context\tnext\tkneser_ney_p\tcache_p\tmixed_p"
    gains = dev_kneser_ney.each_index.map do |i|
      mixed = RecencyMixture.probability(dev_kneser_ney[i], cache[i], weights[levels[i]])
      {Math.log2(mixed / dev_kneser_ney[i]), i}
    end.to_a.sort_by { |gain, _| -gain }
    shown = Set(String).new
    gains.each do |_, i|
      break if shown.size >= 8
      position = dev_start + i
      label = display_bytes(corpus[position - 20, 20])
      next unless shown.add?(label[-10..] + corpus[position].chr)
      mixed = RecencyMixture.probability(dev_kneser_ney[i], cache[i], weights[levels[i]])
      puts "#{label}\t#{display_byte(corpus[position])}\t#{dev_kneser_ney[i].round(4)}\t#{cache[i].round(4)}\t#{mixed.round(4)}"
    end

    test_kneser_ney = kneser_ney_for.call(test_start, test_start, corpus.size)
    test_cache, test_levels = cache_for.call(span, test_start, corpus.size)
    test_base = test_kneser_ney.sum { |p| -Math.log2(p) } / test_kneser_ney.size
    test_bits = mixed_bits.call(test_kneser_ney, test_cache, test_levels, weights)
    puts "test: [#{test_start},#{corpus.size}), Kneser–Ney counts from [0,#{test_start}), span and weights from development"
    puts "kneser_ney_bits_per_byte=#{test_base.round(4)}"
    puts "with_recency_bits_per_byte=#{test_bits.round(4)} change=#{(test_bits - test_base).round(4)}"
  end

  # Parses name=value options into integer lists, starting from defaults.
  def self.list_options(args : Array(String), defaults : Hash(String, Array(Int32))) : Hash(String, Array(Int32))
    options = defaults.dup
    args.each do |arg|
      name, _, value = arg.partition('=')
      raise ArgumentError.new("unknown option #{name.inspect}") unless options.has_key?(name)
      options[name] = value.split(',').map { |item| parse_positive(item) }
    end
    options
  end

  def self.lattice(args : Array(String)) : Nil
    raise ArgumentError.new(USAGE) if args.empty?
    corpus = File.read(args.shift).to_slice
    options = list_options(args, {"window" => [16], "k" => [1, 4, 16, 64], "support" => [2, 5, 10, 25], "stride" => [20]})
    window = options["window"].first
    ks = options["k"].sort
    stride = options["stride"].first
    test_start = training_end(corpus.size)
    dev_start = training_end(test_start)
    # Mean bits per byte on every stride-th byte of [start, finish), for each k,
    # with counts from [0, start); and Kneser–Ney on the same bytes.
    score = ->(start : Int32, finish : Int32, support : Int32, counts : Array(Int32)) do
      index = Index.from_bytes(corpus[0, start])
      predictor = LatticePredictor.new(index, window, support, counts.max)
      kneser_ney = KneserNey.new(SuffixArray.new(corpus[0, start]), 6)
      positions = (start...finish).step(stride).to_a
      bits = Array(Float64).new(counts.size, 0.0)
      reference = 0.0
      started = Time.instant
      positions.each do |position|
        history = corpus[0, position]
        patterns = predictor.patterns(history)
        counts.each_with_index { |k, i| bits[i] -= Math.log2(predictor.probability(patterns, corpus[position], k)) }
        reference -= Math.log2(kneser_ney.probability(history, corpus[position], 6))
      end
      seconds = (Time.instant - started).total_seconds
      {bits.map { |sum| sum / positions.size }, reference / positions.size, positions.size, seconds}
    end

    puts "options: window=#{window} k=#{ks.join(',')} support=#{options["support"].join(',')} stride=#{stride}"
    puts "development: every #{stride}th byte of [#{dev_start},#{test_start}), counts from [0,#{dev_start})"
    puts "support\t#{ks.map { |k| "k=#{k}" }.join('\t')}\tkneser_ney\tms_per_byte"
    results = options["support"].map do |support|
      bits, reference, sampled, seconds = score.call(dev_start, test_start, support, ks)
      puts "#{support}\t#{bits.map(&.round(4)).join('\t')}\t#{reference.round(4)}\t#{(1000 * seconds / sampled).round(2)}"
      {support, bits}
    end
    support, k, _ = results.flat_map { |s, bits| ks.each_with_index.map { |k, i| {s, k, bits[i]} }.to_a }.min_by { |entry| entry[2] }
    bits, reference, sampled, _ = score.call(test_start, corpus.size, support, [k])
    puts "test: every #{stride}th byte of [#{test_start},#{corpus.size}), #{sampled} bytes, counts from [0,#{test_start}), support=#{support} k=#{k}"
    puts "kneser_ney_bits_per_byte=#{reference.round(4)}"
    puts "lattice_bits_per_byte=#{bits[0].round(4)} change=#{(bits[0] - reference).round(4)}"
  end

  def self.neighbors(args : Array(String)) : Nil
    raise ArgumentError.new(USAGE) if args.size < 2
    corpus = File.read(args.shift).to_slice
    history = literal_bytes(args.shift)
    options = list_options(args, {"window" => [16], "k" => [16], "support" => [2]})
    counts_end = training_end(corpus.size)
    predictor = LatticePredictor.new(Index.from_bytes(corpus[0, counts_end]), options["window"].first, options["support"].first, options["k"].first)
    patterns = predictor.patterns(history)
    total = patterns.sum(&.weight)
    puts "context=#{display_bytes(history)} counts_from=[0,#{counts_end}) window=#{options["window"].first} support>=#{options["support"].first}"
    puts "rank\tpattern\tsupport\tloo_bits\tweight\tshare\ttop_next"
    patterns.each_with_index do |pattern, rank|
      top = (0...predictor.alphabet.size).to_a.sort_by { |slot| -pattern.counts[slot] }.first(3).select { |slot| pattern.counts[slot] > 0 }
      next_text = top.map { |slot| "#{display_byte(predictor.alphabet[slot])}:#{pattern.counts[slot]}" }.join(' ')
      puts "#{rank + 1}\t\"#{predictor.display(pattern.shape, history)}\"\t#{pattern.support}\t#{pattern.bits.round(3)}\t#{pattern.weight.round(3)}\t#{(pattern.weight / total).round(3)}\t#{next_text}"
    end
    distribution = predictor.distribution(patterns)
    puts "next\tprobability"
    (0..255).to_a.sort_by { |byte| -distribution[byte] }.first(8).each do |byte|
      puts "#{display_byte(byte.to_u8)}\t#{distribution[byte].round(4)}"
    end
  end

  # Splits off a name=list option of non-negative decimals.
  def self.decimal_option(args : Array(String), name : String, default : Array(Float64)) : Array(Float64)
    found = args.find { |arg| arg.starts_with?("#{name}=") }
    return default unless found
    args.delete(found)
    found.partition('=')[2].split(',').map do |item|
      value = item.to_f?
      raise ArgumentError.new("#{name} needs non-negative numbers") unless value && value >= 0
      value
    end
  end

  def self.sufficiency(args : Array(String)) : Nil
    raise ArgumentError.new(USAGE) if args.empty?
    corpus = File.read(args.shift).to_slice
    priors = decimal_option(args, "prior", [0.5, 2.0, 8.0])
    discounts = decimal_option(args, "discount", [] of Float64).map(&.as(Float64?))
    discounts = [nil.as(Float64?)] if discounts.empty?
    chains = decimal_option(args, "chain", [] of Float64).map(&.as(Float64?))
    chains = [nil.as(Float64?)] if chains.empty?
    nearests = decimal_option(args, "nearest", [] of Float64).map(&.as(Float64?))
    nearests = [nil.as(Float64?)] if nearests.empty?
    offset = decimal_option(args, "offset", [0.0]).first.to_i
    suffixes_only = !args.delete("suffixes").nil?
    hierarchical = !args.delete("hierarchical").nil?
    score_test = !args.delete("test").nil?
    options = list_options(args, {"window" => [16], "support" => [2, 10], "stride" => [100]})
    window = options["window"].first
    stride = options["stride"].first
    raise ArgumentError.new("offset must be less than the stride") unless offset < stride
    test_start = training_end(corpus.size)
    dev_start = training_end(test_start)
    # Bits per byte on every stride-th byte of [start, finish), counts from
    # [0, start), against Kneser–Ney on the same bytes: means, the paired
    # standard error of the difference, and the weighted pattern depth.
    score = ->(start : Int32, finish : Int32, support : Int32, prior : Float64, discount : Float64?, chain : Float64?, nearest : Float64?) do
      predictor = SufficiencyPredictor.new(Index.from_bytes(corpus[0, start]), window, support, prior,
        suffixes_only: suffixes_only, hierarchical: hierarchical, discount: discount, chain_strength: chain, nearest_prior: nearest)
      kneser_ney = KneserNey.new(SuffixArray.new(corpus[0, start]), 6)
      positions = (start + offset...finish).step(stride).to_a
      differences = [] of Float64
      bits = 0.0
      reference = 0.0
      depth = 0.0
      started = Time.instant
      positions.each do |position|
        history = corpus[0, position]
        patterns = predictor.patterns(history)
        model = -Math.log2(predictor.probability(patterns, corpus[position]))
        baseline = -Math.log2(kneser_ney.probability(history, corpus[position], 6))
        bits += model
        reference += baseline
        differences << model - baseline
        depth += patterns.sum { |pattern| pattern.weight * pattern.shape.popcount }
      end
      seconds = (Time.instant - started).total_seconds
      n = positions.size
      mean = differences.sum / n
      error = Math.sqrt(differences.sum { |d| (d - mean) ** 2 } / (n - 1) / n)
      {bits / n, reference / n, error, depth / n, n, seconds}
    end

    puts "options: window=#{window} support=#{options["support"].join(',')} prior=#{priors.join(',')} discount=#{discounts.map { |d| d || "none" }.join(',')} chain=#{chains.map { |c| c || "none" }.join(',')} nearest=#{nearests.map { |n| n || "uniform" }.join(',')} stride=#{stride} offset=#{offset}#{suffixes_only ? " suffixes" : ""}#{hierarchical ? " hierarchical" : ""}"
    puts "development: every #{stride}th byte of [#{dev_start + offset},#{test_start}), counts from [0,#{dev_start})"
    puts "support\tprior\tdiscount\tchain\tnearest\tbits_per_byte\tkneser_ney\tchange\tpaired_se\tdepth\tms_per_byte"
    results = options["support"].flat_map do |support|
      priors.flat_map do |prior|
        discounts.flat_map do |discount|
          chains.flat_map do |chain|
            nearests.map do |nearest|
              bits, reference, error, depth, sampled, seconds = score.call(dev_start, test_start, support, prior, discount, chain, nearest)
              puts "#{support}\t#{prior}\t#{discount || "none"}\t#{chain || "none"}\t#{nearest || "uniform"}\t#{bits.round(4)}\t#{reference.round(4)}\t#{(bits - reference).round(4)}\t#{error.round(4)}\t#{depth.round(2)}\t#{(1000 * seconds / sampled).round(1)}"
              {support, prior, discount, chain, nearest, bits}
            end
          end
        end
      end
    end
    support, prior, discount, chain, nearest, _ = results.min_by { |entry| entry[5] }
    puts "chosen: support=#{support} prior=#{prior} discount=#{discount || "none"} chain=#{chain || "none"} nearest=#{nearest || "uniform"}"
    if score_test
      bits, reference, error, depth, sampled, _ = score.call(test_start, corpus.size, support, prior, discount, chain, nearest)
      puts "test: every #{stride}th byte of [#{test_start},#{corpus.size}), #{sampled} bytes, counts from [0,#{test_start})"
      puts "kneser_ney_bits_per_byte=#{reference.round(4)}"
      puts "sufficiency_bits_per_byte=#{bits.round(4)} change=#{(bits - reference).round(4)} paired_se=#{error.round(4)} depth=#{depth.round(2)}"
    end
  end

  def self.sufficient(args : Array(String)) : Nil
    raise ArgumentError.new(USAGE) if args.size < 2
    corpus = File.read(args.shift).to_slice
    history = literal_bytes(args.shift)
    prior = decimal_option(args, "prior", [2.0]).first
    discount = decimal_option(args, "discount", [] of Float64).first?
    chain = decimal_option(args, "chain", [] of Float64).first?
    nearest = decimal_option(args, "nearest", [] of Float64).first?
    suffixes_only = !args.delete("suffixes").nil?
    hierarchical = !args.delete("hierarchical").nil?
    options = list_options(args, {"window" => [16], "support" => [2]})
    counts_end = training_end(corpus.size)
    predictor = SufficiencyPredictor.new(Index.from_bytes(corpus[0, counts_end]), options["window"].first, options["support"].first, prior,
      suffixes_only: suffixes_only, hierarchical: hierarchical, discount: discount, chain_strength: chain, nearest_prior: nearest)
    patterns = predictor.patterns(history)
    puts "context=#{display_bytes(history)} counts_from=[0,#{counts_end}) window=#{options["window"].first} support>=#{options["support"].first} prior=#{prior}"
    puts "patterns_with_weight=#{patterns.size}"
    puts "rank\tpattern\tsupport\tweight\ttop_next"
    patterns.first(12).each_with_index do |pattern, rank|
      top = (0...predictor.alphabet.size).to_a.sort_by { |slot| -pattern.counts[slot] }.first(4).select { |slot| pattern.counts[slot] > 0 }
      next_text = top.map { |slot| "#{display_byte(predictor.alphabet[slot])}:#{pattern.counts[slot]}" }.join(' ')
      puts "#{rank + 1}\t\"#{predictor.display(pattern.shape, history)}\"\t#{pattern.support}\t#{pattern.weight.round(4)}\t#{next_text}"
    end
    distribution = predictor.distribution(patterns)
    puts "next\tprobability"
    (0..255).to_a.sort_by { |byte| -distribution[byte] }.first(8).each do |byte|
      puts "#{display_byte(byte.to_u8)}\t#{distribution[byte].round(4)}"
    end
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
    when "interactions"
      interactions(args)
    when "residual"
      residual(args)
    when "recency"
      recency(args)
    when "lattice"
      lattice(args)
    when "neighbors"
      neighbors(args)
    when "sufficiency"
      sufficiency(args)
    when "sufficient"
      sufficient(args)
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
