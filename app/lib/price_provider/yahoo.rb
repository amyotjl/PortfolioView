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
      series = build_series(sym, get_json("/v8/finance/chart/#{sym}", params))
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

    def build_series(sym, body)
      result = extract_result!(sym, body)
      meta = result["meta"] || {}
      # Bars are keyed by the EXCHANGE's calendar date, not UTC. Yahoo's
      # timestamps are the session's opening instant in UTC epoch, so a TSX bar
      # at 13:30 UTC is 09:30 local — the same day here, but an exchange east
      # of UTC would land on the previous day if this were read as UTC.
      offset = meta["gmtoffset"].to_i

      splits, adjustments, split_warnings = build_splits(sym, result)
      bars, bar_warnings = build_bars(sym, result, offset)
      # ADJUSTMENTS, not splits: prices must be un-adjusted by every factor
      # Yahoo applied, including reinvested distributions that never moved the
      # share count. See #build_splits.
      unadjust!(bars, adjustments)

      DailySeries.new(symbol: sym,
                      bars: bars.sort_by!(&:date).freeze,
                      splits: splits.sort_by!(&:ex_date).freeze,
                      dividends: build_dividends(result, offset).freeze,
                      warnings: (split_warnings + bar_warnings).freeze)
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

    # A Yahoo "split" event is a PRICE-ADJUSTMENT FACTOR. Most are also
    # share-count events — but not all, and conflating the two corrupts
    # holdings. This returns both lists deliberately:
    #
    #   adjustments — every factor, used ONLY to reverse Yahoo's price maths
    #   splits      — the subset that genuinely changed the share count, which
    #                 is all Holdings::Calculator may ever see
    #
    # WHY THE DISTINCTION IS NOT THEORETICAL. Canadian ETFs declare a year-end
    # REINVESTED capital-gains distribution: unitholders are allocated new
    # units and the fund immediately consolidates them, so the price drops and
    # the unit count is UNCHANGED. Yahoo models the price effect as a
    # split-shaped factor just under 1 — real examples from this portfolio:
    #
    #   ZEQT.TO  2025-12-30  993:1000
    #   VDY.TO   2024-12-30  994:1000
    #   VDY.TO   2025-12-30  987:1000
    #
    # Stored as SplitEvents those would shrink the holder's shares by ~0.7% on
    # a day nothing was issued or consolidated. The user's own broker data
    # settles it: #68's activity ledger reconciled 13 of 14 positions using the
    # 3:1 of 2025-08-18 ALONE, which it could not have done if the 993:1000 had
    # moved unit counts. Yahoo's prices ARE adjusted by it, though, so it still
    # belongs in `adjustments` — dropping it outright would leave every
    # pre-2025-12-30 ZEQT price 0.7% below what actually traded.
    #
    # SPIN-OFFS ARRIVE IN THE SAME SHAPE, and that is why this rule is about the
    # DENOMINATOR ALONE. An earlier version also required the ratio to sit near
    # 1, which made the classification depend on MAGNITUDE rather than on the
    # property that matters — whether the share count moved. #66's gate found
    # real securities that routes here and broke it:
    #
    #   TRP.TO  1097:1000  2024-10-02  South Bow spin-off  -> +9.7% phantom shares
    #   BN.TO   1237:1000  2022-12-12  BAM spin-off        -> +23.7% phantom shares
    #   BN.TO   1033:1000  2013-04-15  BPY spin-off        -> suppressed
    #
    # The same corporate action classified two different ways purely by size.
    # And a spin-off does NOT change the parent's share count either: holders
    # keep their shares and receive new ones in the spun-off entity, so Yahoo's
    # factor is a price adjustment exactly as a reinvested distribution is.
    #
    # AND `num > 1`, WHICH IS THE MIRROR-IMAGE HOLE. Dropping the ratio band
    # fixed spin-offs and immediately broke CONSOLIDATIONS: a reverse split
    # arrives as `1:300`, so a denominator test alone routes the most
    # share-count-changing event there is into the price-only branch. The old
    # band excluded it only by accident (0.0033 fell outside 0.95..1.05).
    #
    # It was live on real holdings. `HMMC.TO` has a 1:300 consolidation on
    # 2023-01-04 — suppressing it makes a backdated buy report CAD 1,230 against
    # a true CAD 4.10 — and `VTI.CN`, now typeable through the new autocomplete,
    # carries two 1:100 events that turn a CAD 1.00 position into CAD 2,100.
    #
    # So both halves are needed, and each covers what the other misses:
    #
    #   den >= 100   a distribution (993:1000) or a spin-off (1097:1000) —
    #                price-only, the share count did not move
    #   num > 1      ...but NOT a consolidation (1:300), which is a genuine
    #                share-count event that also has a large denominator
    #
    # A real split is otherwise a small-integer ratio — 4:1, 3:2, 1:8, 21:20 —
    # because that is what a split IS. Verified across all 15 genuine and 13
    # price-only factors observed on this feed: 15/15 kept, 13/13 suppressed.
    # Every suppression warns, never silently.
    DISTRIBUTION_MIN_DENOMINATOR = 100

    def build_splits(sym, result)
      warnings = []
      adjustments = []
      splits = []

      (result.dig("events", "splits") || {}).values.each do |ev|
        ex_date = date_at(ev["date"], result.dig("meta", "gmtoffset").to_i)
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

        adjustments << Split.new(ex_date:, ratio:)

        if den >= DISTRIBUTION_MIN_DENOMINATOR && num > 1
          warnings << skip_warning(sym, "treated #{num.to_i}:#{den.to_i} on #{ex_date} as a " \
            "price-only corporate action (reinvested distribution or spin-off), not a " \
            "share-count split — prices are un-adjusted by it, holdings are not")
        else
          splits << Split.new(ex_date:, ratio:)
        end
      end

      [ splits, adjustments, warnings ]
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
