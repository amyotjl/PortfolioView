module Demo
  # Creates the instruments Demo::Seeder trades, which is what triggers their
  # full-history price backfill and one-time FMP sector lookup (see
  # Instrument's after_create_commit hooks).
  #
  # Separate from the seeder, and run first, because backfill is ASYNCHRONOUS:
  # the jobs go through Solid Queue and are paced against Tiingo's free-tier
  # budget, so prices land seconds-to-minutes later. The seeder then refuses to
  # run against a symbol that has no history rather than quietly building a
  # portfolio whose market value is zero.
  #
  # The CAD names are deliberately absent: they carry a venue suffix, route to
  # Yahoo instead of Tiingo, and are already present in any database that has
  # imported the Canadian directory (issue #66).
  module Instruments
    US_EQUITIES = {
      "NVDA" => "NVIDIA Corporation",
      "AMZN" => "Amazon.com, Inc.",
      "GOOGL" => "Alphabet Inc.",
      "JPM" => "JPMorgan Chase & Co.",
      "V" => "Visa Inc.",
      "UNH" => "UnitedHealth Group Incorporated",
      "JNJ" => "Johnson & Johnson",
      "XOM" => "Exxon Mobil Corporation",
      "COST" => "Costco Wholesale Corporation",
      "HD" => "The Home Depot, Inc.",
      "KO" => "The Coca-Cola Company",
      "PG" => "The Procter & Gamble Company",
      "CAT" => "Caterpillar Inc."
    }.freeze

    def self.call(io: $stdout)
      US_EQUITIES.each do |symbol, name|
        existing = Instrument.find_by("upper(symbol) = ?", symbol)
        if existing
          io.puts "= #{symbol} (#{existing.daily_prices.count} bars)"
          next
        end
        Instrument.create!(symbol: symbol, name: name, instrument_type: "stock", currency: "USD")
        io.puts "+ #{symbol} created — backfill and metadata enqueued"
      end

      budget = PriceProvider::Budget.new("tiingo")
      io.puts "tiingo budget: #{budget.remaining_today} requests left today, " \
              "#{budget.remaining_symbols_this_month} unique symbols left this month"
    end
  end
end
