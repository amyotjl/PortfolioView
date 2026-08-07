module PriceProvider
  # Yahoo Finance EOD adapter — the ONLY configured source of Canadian
  # (TSX / TSX-V / CBOE Canada) daily history (issue #66). Tiingo's directory
  # contains zero Canadian rows, FMP answers 402 for `.TO`, and Twelve Data
  # gates those symbols behind its paid Grow tier, so without this adapter a
  # CAD holding has no price coverage at all and its market value reads as zero.
  #
  # THREE THINGS TO KNOW BEFORE TOUCHING THIS FILE
  #
  # 1. **It is an unofficial endpoint.** `/v8/finance/chart` powers Yahoo's own
  #    website; it is not a documented, licensed product, and automated use is
  #    contrary to Yahoo's terms. It was adopted deliberately, with that
  #    understood, for a personal single-user deployment that redistributes
  #    nothing. It can break without notice, so every caller must treat a Yahoo
  #    failure as "no new prices today", never as data loss — cost basis is
  #    stored independently and stays exact.
  #
  # 2. **Yahoo's OHLC is SPLIT-ADJUSTED. This app stores RAW.** That mismatch is
  #    the whole reason #unadjust! exists; read its comment before changing
  #    anything about price handling.
  #
  # 3. **No API key.** `API_KEY_ENV = nil` (see Base#initialize). There is
  #    therefore no Budget to charge and no quota to respect — but also no
  #    published rate limit, and Yahoo does block aggressive callers, so
  #    callers should keep using the same one-request-per-instrument shape the
  #    Tiingo path uses rather than fanning out hard.
  class Yahoo < Base
    # Keyless. Base#initialize skips the credential check when this is nil.
    API_KEY_ENV = nil
    BASE_URL = "https://query1.finance.yahoo.com"

    # Yahoo rejects a negative period1, so full history starts at the epoch
    # rather than Tiingo's 1900-01-01. No instrument this adapter serves — the
    # Canadian ETFs and CDRs — existed before 1970, and Yahoo returns from each
    # symbol's own inception regardless (ZEQT.TO answers from 2022-02-09).
    EPOCH_START = Time.at(0).utc.to_date

    # Matches daily_prices' decimal(16,6). Un-adjustment multiplies, so the
    # rounding has to happen AFTER that arithmetic, not on the wire values.
    PRICE_SCALE = 6
    # Matches split_events.ratio decimal(12,6).
    RATIO_SCALE = 6

    # A plain Faraday UA gets inconsistent treatment from Yahoo; a browser-ish
    # one is what the endpoint expects. No key is being hidden here — this is
    # purely about not being fingerprinted as a bot on a keyless endpoint.
    USER_AGENT = "Mozilla/5.0 (compatible; PortfolioView/1.0)".freeze

    # Yahoo spells a class or series share with a DASH — `ACO-X.TO`,
    # `AQN-PR-A.TO`, `HPS-A.TO`. Every other source this app touches spells it
    # with a dot, including the Twelve Data directory feed that populates
    # `listed_instruments` and therefore the symbol a user picks out of the
    # autocomplete. Measured on the live directory: **1,064** CAD rows carry more
    # than one dot — 913 well-formed plus the 151 malformed `..` rows #66 now
    # drops AT IMPORT (so a directory imported before that fix still holds them;
    # they 404 under either spelling and are not what this translation is for).
    # All 1,064 are `tradeable` and resolvable, so before this they
    # autocompleted, resolved, and then priced to zero (#79).
    #
    # Necessary, not sufficient: some rows are absent from Yahoo under any
    # spelling (AQN.PR.A.TO 404s as AQN-PR-A.TO too — a redeemed preferred), and
    # thinly traded venue duplicates such as ACO.X.NE return a single bar.
    #
    # THE TRANSLATION LIVES HERE, IN THE ADAPTER, AND THAT IS THE WHOLE POINT.
    # The alternatives — restyling the directory at import, or changing what
    # SymbolQualifier mints — both change INSTRUMENT IDENTITY, and `instruments`
    # is UNIQUE on upper(symbol) alone. A user who already imported `ACO.X.TO`
    # would get a second instrument for `ACO-X.TO`: the exact failure
    # `InstrumentResolver#venue_sibling_for` exists to prevent, and one it cannot
    # catch here because the two spellings have different BASE symbols under its
    # match rule. A request-time translation cannot create a duplicate, needs no
    # migration for rows already stored, and fixes every already-imported holding
    # the moment it ships.
    #
    # So the app's spelling stays the app's spelling: `sym` remains what
    # `DailySeries#symbol` and every warning reports, and only the URL differs.
    # `#68`'s `HPS.A.TO` expectation is therefore deliberately UNCHANGED — its
    # gate noted the symbol "is not Yahoo's HPS-A.TO convention", and it no
    # longer needs to be.
    #
    # The venue suffix is stripped before the dots are dashed and re-appended
    # afterwards, because the suffix's own dot is the one dot Yahoo does want.
    # KNOWN_SUFFIXES is reused rather than redefined for the same reason
    # ProviderRouter reuses it: "what counts as a venue suffix" gets exactly one
    # definition, or the importer and the price path drift apart.
    CLASS_SHARE_SEPARATOR = "-".freeze

    def provider_symbol(symbol)
      sym = symbol.to_s.strip.upcase
      base, suffix = split_venue_suffix(sym)

      "#{base.tr('.', CLASS_SHARE_SEPARATOR)}#{suffix}"
    end

    # `to:` filters the RETURNED bars but deliberately does NOT narrow the
    # request. Un-adjusting needs every split AFTER a bar's date, and Yahoo only
    # reports events that fall inside the requested window — so asking for
    # Jan–Jun 2020 returns prices already divided by AAPL's August 4:1 with the
    # split itself absent, and the reconstruction silently under-corrects by
    # exactly that factor (measured: close 91.20 against a true raw 364.80).
    # Requesting through today and slicing afterwards makes that unreachable by
    # construction rather than by the caller remembering. #66's gate found this
    # while it was still latent, because the only live caller passes no `to:`.
    def fetch_daily(symbol, from:, to: nil)
      sym = normalize_symbol(symbol)
      requested = provider_symbol(sym)
      cutoff = to&.to_date
      # period2 is exclusive of the bar's open instant, so today needs +1 or
      # today's bar is dropped.
      params = {
        period1: epoch_for(from.to_date),
        period2: epoch_for(Trading::Calendar.today + 1),
        interval: "1d",
        events: "div,split",
        # adjclose is dividend-adjusted as well and is never stored; asking for
        # it only enlarges the response.
        includeAdjustedClose: "false"
      }
      series = build_series(sym, get_json("/v8/finance/chart/#{requested}", params),
                            requested: requested)
      cutoff ? slice_to(series, cutoff) : series
    end

    def fetch_full_history(symbol, to: nil) = fetch_daily(symbol, from: EPOCH_START, to: to)

    private

    # Applied AFTER un-adjustment, so the prices are already reconstructed with
    # the full split history before anything is discarded. Events outside the
    # window go too: a caller asking for a past window must not be handed a
    # future split to write.
    def slice_to(series, cutoff)
      DailySeries.new(
        symbol: series.symbol,
        bars: series.bars.select { |b| b.date <= cutoff }.freeze,
        splits: series.splits.select { |s| s.ex_date <= cutoff }.freeze,
        dividends: series.dividends.select { |d| d.ex_date <= cutoff }.freeze,
        warnings: series.warnings
      )
    end

    def default_headers = super.merge("User-Agent" => USER_AGENT)

    def epoch_for(date) = [ date.to_time(:utc).to_i, 0 ].max

    # Longest match wins, so `.TO` is never mistaken for Tokyo's `.T`.
    def split_venue_suffix(sym)
      suffix = Portfolios::Transfer::SymbolQualifier::KNOWN_SUFFIXES
               .select { |s| sym.end_with?(s) }
               .max_by(&:length)

      suffix ? [ sym.delete_suffix(suffix), suffix ] : [ sym, "" ]
    end

    # Both spellings when they differ: a "not found" naming only one of them
    # sends whoever reads the log looking in the wrong place.
    def symbol_label(sym, requested)
      sym == requested ? sym : "#{sym} (requested as #{requested})"
    end

    def build_series(sym, body, requested: sym)
      result = extract_result!(symbol_label(sym, requested), body)
      meta = result["meta"] || {}
      # Bars are keyed by the EXCHANGE's calendar date, not UTC. Yahoo's
      # timestamps are the session's opening instant in UTC epoch, so a TSX bar
      # at 13:30 UTC is 09:30 local — the same day here, but an exchange east
      # of UTC would land on the previous day if this were read as UTC.
      offset = meta["gmtoffset"].to_i

      adjustments, factor_warnings = build_adjustments(sym, result)
      bars, bar_warnings = build_bars(sym, result, offset)

      # ORDER IS LOAD-BEARING, TWICE OVER.
      #
      # `classify_splits` reads the bars while they still carry YAHOO'S OWN
      # ADJUSTED closes, because the whole classification turns on whether that
      # series is continuous across the ex-date (see #classify_splits). Running it
      # after #unadjust! would measure the series this adapter reconstructed —
      # which has every factor divided back out — and the gap would then be a
      # function of the factor being tested rather than evidence about it. The
      # test suite pins the order for exactly that reason.
      #
      # And #unadjust! takes ADJUSTMENTS, not splits: prices must be un-adjusted
      # by every factor Yahoo applied, including the ones that never moved a share
      # count. Dropping those would leave the whole pre-event history off by them.
      splits, split_warnings = classify_splits(sym, adjustments, bars)
      unadjust!(bars, adjustments)

      DailySeries.new(symbol: sym,
                      bars: bars.sort_by!(&:date).freeze,
                      splits: splits.sort_by!(&:ex_date).freeze,
                      dividends: build_dividends(result, offset).freeze,
                      warnings: (factor_warnings + split_warnings + bar_warnings).freeze)
    end

    # Yahoo answers HTTP 200 with a null result and an error object for an
    # unknown or delisted symbol, so Base#handle_status! never sees it.
    def extract_result!(sym, body)
      unless body.is_a?(Hash) && body["chart"].is_a?(Hash)
        raise MalformedResponse, "#{provider_name}: response for #{sym} has no chart object"
      end

      chart = body["chart"]
      if (err = chart["error"])
        code = err.is_a?(Hash) ? err["code"] : err
        raise UnknownSymbol, "#{provider_name}: #{sym} not found (#{code})"
      end

      result = Array(chart["result"]).first
      raise UnknownSymbol, "#{provider_name}: #{sym} returned no result" if result.nil?

      result
    end

    def build_bars(sym, result, offset)
      timestamps = result["timestamp"] || []
      quote = (result.dig("indicators", "quote") || []).first || {}
      warnings = []

      bars = timestamps.each_with_index.filter_map do |ts, i|
        date = date_at(ts, offset)
        open, high, low, close = %w[open high low close].map { |k| to_decimal((quote[k] || [])[i]) }

        # Yahoo pads holidays, halts and pre-inception days with nulls. Those
        # are expected and silent; anything else is reported, matching Tiingo's
        # validate-and-skip posture so one bad row can never poison the batch.
        next if date && [ open, high, low, close ].all?(&:nil?)

        unless date && valid_ohlc?(open, high, low, close)
          warnings << skip_warning(sym, "skipped bad EOD row ts=#{ts.inspect} " \
            "open=#{open.inspect} high=#{high.inspect} low=#{low.inspect} close=#{close.inspect}")
          next
        end

        # Rounded HERE, not only in #unadjust!, so every bar leaves this adapter
        # at the same scale. Yahoo sends IEEE floats (a close of 129.04 arrives
        # as 129.0399932861328), and a bar with no later split skips the
        # un-adjust path entirely — without this it would escape carrying that
        # noise while its split-adjusted neighbours came back clean.
        # Re-rounding after the multiply is safe: the factor is a ratio of
        # integers, so scaling an already-rounded value stays exact.
        Bar.new(date:,
                open: open.round(PRICE_SCALE), high: high.round(PRICE_SCALE),
                low: low.round(PRICE_SCALE), close: close.round(PRICE_SCALE),
                volume: ((quote["volume"] || [])[i]).to_i)
      end

      [ bars, warnings ]
    end

    # A Yahoo "split" event is a PRICE-ADJUSTMENT FACTOR, and only SOME of those
    # factors also moved the share count. Two lists come out of this file:
    #
    #   adjustments — every factor, used ONLY to reverse Yahoo's price maths
    #   splits      — the subset that genuinely changed the share count, which is
    #                 all Holdings::Calculator may ever see
    #
    # Conflating them corrupts holdings in one direction; separating them wrongly
    # corrupts holdings in the other. Both have already shipped here and both were
    # caught by a gate, so read this whole comment before touching the rule.
    #
    # THE THREE FAILED ATTEMPTS, because each one is a trap worth not re-entering:
    #
    #   round 1  `den >= 100 && ratio.between?(0.95, 1.05)` — classified by
    #            MAGNITUDE, so `TRP.TO 1097:1000` (the South Bow spin-off) and
    #            `BN.TO 1237:1000` (BAM) became SplitEvents worth +9.7% and +23.7%
    #            phantom shares, while `BN.TO 1033:1000`, the same corporate action
    #            at a different size, was suppressed correctly.
    #   round 2  `den >= 100` alone — fixed the spin-offs and swallowed
    #            CONSOLIDATIONS, which arrive as `1:300`. `HMMC.TO`'s 1-for-300
    #            made a backdated buy report CAD 1,230 against a true CAD 4.10.
    #   round 3  `den >= 100 && num > 1` — rescued a consolidation only when the
    #            numerator was exactly 1, so `LUG.TO 100:270`, `WCN.TO 4815:10000`
    #            and `WKHS 8:100` stayed suppressed; and it split one fund's single
    #            annual action two ways, keeping `XCS.TO 9:10` (destroying 10% of
    #            the position) while suppressing the same fund's `96:100`.
    #
    # THE LESSON, in the round-3 gate's words: "(num, den) encodes the WRITTEN FORM
    # of the fraction, and Yahoo's written form is not a function of the event
    # class." Measured across 482 real events it found the distribution family
    # written as 9:10, 88:100, 94:100, 96:100, 97:100, 99:100 AND n:1000, and
    # genuine consolidations written as 1:300 AND 8:100, 100:270, 4815:10000. No
    # threshold on the pair can separate those. So this rule does not try: it asks
    # the PRICE SERIES what happened, and falls back on the written form only where
    # the series cannot answer.
    #
    # ── THE EVIDENCE ────────────────────────────────────────────────────────────
    #
    # Yahoo divides every pre-ex-date close by the factor. So its own series says
    # whether the traded price actually moved:
    #
    #   a genuine split or consolidation — the raw price really moved by 1/ratio,
    #     Yahoo's adjustment cancels it, and the ADJUSTED series is CONTINUOUS
    #     across the ex-date:            close_before / close_after ≈ 1
    #
    #   a reinvested distribution — unitholders are allocated new units and the
    #     fund immediately consolidates them, so the unit count and the price are
    #     both UNCHANGED. Yahoo adjusts anyway, leaving a step in the adjusted
    #     series of exactly the factor:  close_before / close_after ≈ 1 / ratio
    #
    # That is a physical difference, not a threshold, and it holds however Yahoo
    # chose to write the fraction. It is what finally separates `XCS.TO 9:10`
    # (gap 1.1122 against 1/ratio 1.1111 — price-only) from `FTN.TO 11:10`
    # (gap 0.9693 against 1/ratio 0.9091 — a real subdivision), two events the
    # written form cannot tell apart at all.
    #
    # ── WHERE THE EVIDENCE RUNS OUT: SPIN-OFFS ──────────────────────────────────
    #
    # A spin-off does NOT change the parent's share count — holders keep their
    # shares and receive new ones in the spun-off entity — but the parent's price
    # DOES drop by the value distributed, so Yahoo's factor is a real price
    # adjustment and the adjusted series is continuous. A spin-off is therefore
    # indistinguishable from a genuine subdivision BY PRICE ALONE. Measured: TRP.TO
    # 1097:1000 has gap 1.0015, as continuous as AAPL's 4:1.
    #
    # The one thing that does separate them is the written form after all — but the
    # OTHER half of it, and only inside the band where a price-only action is even
    # possible. A split is DECLARED, so its ratio is a small-integer exchange ratio
    # (4:1, 3:2, 11:10, 6:5, 114:100 → 57/50). A spin-off or distribution factor is
    # DERIVED FROM MARKET PRICES, so it is an arbitrary decimal over a power of ten
    # (1097:1000, 1237:1000, 10000:9607, 1055:1000 → 211/200). Hence
    # MAX_DECLARED_DENOMINATOR, applied to the fraction in LOWEST TERMS.
    #
    # ── THE RULE ────────────────────────────────────────────────────────────────
    #
    #   1. ratio outside NEAR_ONE_BAND        -> SHARE-COUNT, unconditionally.
    #      No reinvested distribution or spin-off is worth 30% of a security's
    #      value, let alone the 100x of a `1:100`. This guard is what keeps a
    #      consolidation safe no matter how Yahoo wrote it or what its series
    #      looks like, and it is why round 2's and round 3's blockers cannot
    #      recur. It also absorbs a real Yahoo data-quality wrinkle: on thin
    #      TSXV/CSE listings the series is sometimes NOT adjusted for the
    #      operator's own factor (`RAGE.V 1:2` has gap 2.0000, `VVTM.V 1:100`
    #      has gap 99.9999), which the gap test alone would read as price-only
    #      and turn into a 2x–100x share error.
    #   2. denominator in lowest terms > MAX_DECLARED_DENOMINATOR -> PRICE-ONLY.
    #      A market-derived decimal near 1: a distribution or a spin-off.
    #   3. otherwise ask the series, requiring GAP_MARGIN of separation.
    #   4. no bar on one side -> SHARE-COUNT: what reaches here is a DECLARED
    #      exchange ratio (rule 2 sent the market-derived ones away), and that is a
    #      share-count change by definition. It is also the inconsequential case —
    #      with no earlier close, #unadjust! has nothing to scale either way.
    #
    # ── HOW THE RULE WAS CHOSEN, AND WHAT IT COSTS ──────────────────────────────
    #
    # Not from a hand-picked list. `#71` earned that rule the hard way and the
    # round-3 gate restated it: a sample chosen by the person proposing the tier
    # always flatters them. So the sweep was a DETERMINISTIC symbol set — every CAD
    # instrument the real Wealthsimple import created, every symbol named in any of
    # the three gate rounds, an evenly-spaced sample across the whole Canadian
    # directory, and US controls with known corporate histories.
    #
    # The sweep: 1,797 symbols requested, 789 distinct factors found on 423 of them
    # — against the round-3 gate's own 482 factors on 209 symbols.
    #
    # Scored by driving THIS METHOD over all of it, against 35 events whose truth is
    # independently known (public corporate actions plus every case the three gates
    # named): THIS RULE 35/35. The shipped round-3 rule: 28/35. The two disagree on
    # 24 of the 789, every one in the direction of the known truth. Only 3 of 789
    # are close calls, and no factor outside the band is suppressed — the direction
    # that produced rounds 2 and 3's blockers is closed by construction, not by
    # tuning.
    #
    # In-band population, which is what makes the band worth having: 108 price-only
    # against 8 share-count. Outside it, 681 share-count against 0 price-only.
    #
    # Two known imperfections, stated rather than papered over:
    #
    #   * `VOD 7:8` (2006) is classified price-only and is really a 7-for-8
    #     consolidation — Vodafone returned capital AND consolidated in one action,
    #     so the price moved for both reasons and the gap (1.1708) sits nearer the
    #     price-only hypothesis (1.1429) than the share-count one. US-routed, so
    #     Yahoo is never consulted for it today (ProviderRouter sends US symbols to
    #     Tiingo); it is here because it is the one counter-example found.
    #   * `GURU.TO 11:1000` (ratio 0.011) is classified SHARE-COUNT, where round 2's
    #     gate note called suppression correct. There is no bar on either side of
    #     the ex-date (the series starts later), so there is no evidence either way;
    #     a 98.9% factor is far more plausible as a 1-for-91 consolidation than as a
    #     distribution, and rule 1 says so. Nothing observable supports either
    #     reading, and no price exists before that date for it to affect.
    #
    # Every price-only classification warns, and so does every fallback. Nothing
    # here is ever silent.

    # A price-only corporate action moves a few percent of a security's value; it
    # never moves 30%. Chosen from the data, not by taste: across 789 real factors
    # every price-only one lies in [0.875, 1.237], and every genuine share-count
    # event outside that sits well beyond [0.71, 1.4].
    NEAR_ONE_BAND = (1 / 1.4)..1.4

    # A DECLARED exchange ratio is small integers. Applied in lowest terms, so
    # 114:100 (57/50) and 96:100 (24/25) reach the series test while 1097:1000 and
    # 10000:9607 do not.
    MAX_DECLARED_DENOMINATOR = 100

    # The nearer hypothesis always wins; this only decides whether the call gets
    # called out as a CLOSE ONE in the warnings. It is deliberately not a decision
    # threshold — a third "too close to tell" branch would need an arbitrary
    # default, and for a factor this near 1 the cost of being wrong is bounded by
    # the same small number that made it hard to tell. 2% is above ordinary
    # day-to-day noise.
    GAP_MARGIN = Math.log(1.02)

    # Every factor Yahoo reported, unclassified — this is the list #unadjust! must
    # use, and the input to #classify_splits.
    def build_adjustments(sym, result)
      warnings = []
      offset = result.dig("meta", "gmtoffset").to_i

      adjustments = (result.dig("events", "splits") || {}).values.filter_map do |ev|
        ex_date = date_at(ev["date"], offset)
        num = to_decimal(ev["numerator"])
        den = to_decimal(ev["denominator"])

        # numerator/denominator rather than the "3:1" splitRatio string: the
        # string is display text, while these two are the values Yahoo actually
        # divided the prices by.
        unless ex_date && num&.positive? && den&.positive?
          warnings << skip_warning(sym, "skipped unusable split #{ev.inspect}")
          next
        end

        ratio = (num / den).round(RATIO_SCALE)
        next if ratio == 1 # a no-op adjustment is neither

        Factor.new(ex_date:, ratio:, numerator: num, denominator: den)
      end

      [ adjustments.sort_by(&:ex_date), warnings ]
    end

    # Splits Holdings::Calculator may see, plus a warning for every factor left
    # out and every call the evidence could not settle. See the comment above.
    def classify_splits(sym, adjustments, adjusted_bars)
      warnings = []
      closes = adjusted_bars.to_h { |bar| [ bar.date, bar.close ] }
      dates = closes.keys.sort

      splits = adjustments.filter_map do |factor|
        share_count, reason = share_count_event?(factor, closes, dates)

        if share_count
          # A reason on a KEPT factor means the evidence was thin (see the
          # CLOSE CALL branch); a clear-cut split has nothing to report.
          warnings << skip_warning(sym, "#{factor.label} on #{factor.ex_date}: #{reason}") if reason
          next Split.new(ex_date: factor.ex_date, ratio: factor.ratio)
        end

        warnings << skip_warning(sym, "treated #{factor.label} on #{factor.ex_date} as a " \
          "price-only corporate action (#{reason}) — prices are un-adjusted by it, " \
          "holdings are not")
        nil
      end

      [ splits, warnings ]
    end

    # [ share_count_event?, reason ] — the reason is for the warning, so it names
    # the evidence rather than a rule number.
    def share_count_event?(factor, closes, dates)
      return [ true, nil ] unless NEAR_ONE_BAND.cover?(factor.ratio)

      unless factor.declared_ratio?(MAX_DECLARED_DENOMINATOR)
        return [ false, "#{factor.label} is a market-derived decimal near 1, not a declared " \
                        "exchange ratio, so it is a distribution or a spin-off" ]
      end

      gap = adjusted_gap(factor.ex_date, closes, dates)
      # No bar on one side: the series cannot speak, so fall back on the written
      # form, which by now is a DECLARED exchange ratio (the market-derived ones
      # returned above) — and a declared exchange ratio is a share-count change by
      # definition. This is also the inconsequential case: with no close before the
      # ex-date, #unadjust! has nothing to scale either way. A real 5% stock
      # dividend at the very start of a series is exactly this shape.
      return [ true, nil ] if gap.nil?

      # Distance, in log space, to each hypothesis: gap ≈ 1 (the traded price
      # really moved by the factor, so a share count moved with it) versus
      # gap ≈ 1/ratio (the price did not move at all).
      moved = Math.log(gap).abs
      unmoved = Math.log(gap * factor.ratio.to_f).abs
      close_call = (moved - unmoved).abs < GAP_MARGIN
      observed = "the adjusted close moves #{gap.round(4)} across the ex-date, against " \
                 "#{(1 / factor.ratio.to_f).round(4)} if the price never moved"

      return [ true, nil ] if moved < unmoved && !close_call
      if moved < unmoved
        # Kept, but the evidence was thin — say so, since the alternative reading
        # would have left the share count alone.
        return [ true, "CLOSE CALL kept as a share-count event: #{observed}" ]
      end

      [ false, "#{observed}, so the traded price did not move and no share count did " \
               "either#{close_call ? ' (CLOSE CALL)' : ''}" ]
    end

    # close on the last session strictly BEFORE the ex-date, over the close on the
    # first session on or after it. Yahoo adjusts prices strictly before the
    # ex-date, which is the same boundary #unadjust! and Holdings::Calculator use.
    def adjusted_gap(ex_date, closes, dates)
      before = dates.reverse_each.find { |d| d < ex_date }
      after = dates.find { |d| d >= ex_date }
      return nil if before.nil? || after.nil?

      before_close = closes[before]
      after_close = closes[after]
      return nil unless before_close&.positive? && after_close&.positive?

      (before_close / after_close).to_f
    end

    def build_dividends(result, offset)
      (result.dig("events", "dividends") || {}).values.filter_map do |ev|
        ex_date = date_at(ev["date"], offset)
        cash = to_decimal(ev["amount"])
        next unless ex_date && cash&.positive?

        Dividend.new(ex_date:, cash_per_share: cash)
      end.sort_by(&:ex_date)
    end

    def date_at(timestamp, offset)
      return nil unless timestamp.is_a?(Numeric)

      Time.at(timestamp.to_i + offset).utc.to_date
    end

    # THE LOAD-BEARING PART OF THIS ADAPTER.
    #
    # Yahoo returns OHLC already adjusted for every split AFTER the bar's date;
    # Tiingo returns genuinely raw prices plus a splitFactor. This app's storage
    # model is Tiingo's — docs/PLAN.md § Core domain logic: "prices stored
    # unadjusted, splits as events, share counts roll FORWARD at read time" —
    # and Holdings::Calculator applies each split's ratio itself.
    #
    # So storing Yahoo's numbers as-is would apply every split TWICE: AAPL's
    # 2020-08-13 close is $115.01 in Yahoo's feed and $460.04 unadjusted, and
    # the 4:1 event is also present, so the pipeline would have valued that day
    # at a quarter of the truth while the share count was already rolled up.
    #
    # The reverse is exact, because split adjustment is exactly this division:
    #
    #   raw(d) = adjusted(d) × ∏ ratio of splits with ex_date > d
    #
    # Walking the bars newest-first lets that product accumulate in one pass.
    # A split ON the bar's date does NOT apply — Yahoo adjusts prices strictly
    # before the ex-date, the same boundary Holdings::Calculator uses when it
    # rolls a position forward ("a split applies at the START of its ex-date").
    #
    # If Yahoo's split list is ever incomplete the reconstruction is wrong for
    # bars before the missing event — which is why the adapter test compares a
    # reconstructed AAPL against the real Tiingo-sourced rows rather than
    # against itself.
    def unadjust!(bars, splits)
      return bars if splits.empty?

      pending = splits.sort_by(&:ex_date).reverse
      factor = BigDecimal(1)

      bars.sort_by! { |b| b.date }
      bars.reverse!
      bars.map! do |bar|
        factor *= pending.shift.ratio while pending.any? && pending.first.ex_date > bar.date
        next bar if factor == 1

        Bar.new(date: bar.date,
                open: (bar.open * factor).round(PRICE_SCALE),
                high: (bar.high * factor).round(PRICE_SCALE),
                low: (bar.low * factor).round(PRICE_SCALE),
                close: (bar.close * factor).round(PRICE_SCALE),
                volume: bar.volume)
      end
      bars.reverse!
    end
  end
end
