require "test_helper"

# backlog #064 / issue #64: the actual promise of the feature — "move between
# environments or make things easier when rebuilding the database."
#
# The proof is a FIXED POINT: export -> import into a clean account -> export
# again must reproduce the first file byte for byte. Anything the exporter drops,
# the importer misreads, or either one rounds shows up here as a diff, which
# per-service unit tests can miss individually.
class PortfolioTransferRoundTripTest < ActionDispatch::IntegrationTest
  include DomainTestHelper

  setup do
    @source = users(:one)
    @target = users(:two)

    @spy = create_instrument(symbol: "SPY", instrument_type: "etf")
    @benchmark = ::Benchmark.create!(instrument: @spy, name: "S&P 500 (SPY)")

    @aapl = create_instrument(symbol: "AAPL")
    # A non-US listing: the case the local directory cannot resolve and that only
    # survives because instrument identity travels inside the file.
    @zeqt = Instrument.create!(symbol: "ZEQT.TO", name: "BMO All-Equity ETF",
                               instrument_type: "etf", currency: "CAD",
                               sector: "Financials", industry: "Asset Management",
                               skip_provider_jobs: true)
  end

  # Deliberately exercises every field the envelope carries.
  def seed_source_data!
    retirement = create_portfolio(name: "Retirement", user: @source, benchmark: @benchmark)
    taxable = create_portfolio(name: "Taxable", user: @source)

    buy!(retirement, @aapl, on: Date.new(2024, 1, 5), shares: "10.12345678", price: "150.254321", fees: "4.95")
    buy!(retirement, @aapl, on: Date.new(2024, 3, 1), shares: "2", price: "170", kind: "dividend_reinvestment")
    sell!(retirement, @aapl, on: Date.new(2024, 6, 10), shares: "3.5", price: "190.1", fees: "1.25",
          notes: "trimmed the position")

    # A recurring rule plus the transaction it materialized — the linkage that
    # keeps the nightly materializer from re-creating an already-imported slot.
    rule = retirement.recurring_transactions.create!(
      instrument: @aapl, amount_type: "dollars", dollar_amount: "250.5",
      frequency: "monthly", anchor_on: Date.new(2124, 1, 31), next_run_on: Date.new(2124, 1, 31)
    )
    buy!(retirement, @aapl, on: Date.new(2124, 2, 1), shares: "1.5", price: "165",
         recurring_transaction: rule, scheduled_for: Date.new(2124, 1, 31))

    retirement.recurring_transactions.create!(
      instrument: @zeqt, amount_type: "shares", share_amount: "5.25",
      frequency: "quarterly", anchor_on: Date.new(2124, 2, 15), next_run_on: Date.new(2124, 2, 15),
      end_on: Date.new(2130, 1, 1), active: false
    )

    buy!(taxable, @zeqt, on: Date.new(2025, 2, 3), shares: "999.1203", price: "22.100350", fees: "0")
  end

  def export_for(user)
    Portfolios::Transfer::Export.new(user: user, exported_at: Time.utc(2026, 3, 4)).call
  end

  def import_into(user, payload, **kwargs)
    document = Portfolios::Transfer::NativeParser.call(JSON.generate(payload))
    Portfolios::Transfer::Import.call(user: user, document: document, **kwargs)
  end

  # --- The fixed point ---------------------------------------------------------

  test "export -> import -> export reproduces the file exactly" do
    seed_source_data!
    original = export_for(@source)

    result = import_into(@target, original)
    assert_equal 0, result.totals[:portfolios_failed], result.portfolios.map(&:errors).inspect

    assert_equal JSON.pretty_generate(original), JSON.pretty_generate(export_for(@target)),
                 "a round trip must be lossless"
  end

  test "the round trip preserves exact decimal values, not floats" do
    seed_source_data!

    import_into(@target, export_for(@source))

    transaction = @target.portfolios.find_by!(name: "Retirement")
                         .transactions.find_by!(executed_on: Date.new(2024, 1, 5))
    assert_equal BigDecimal("10.12345678"), transaction.shares
    assert_equal BigDecimal("150.254321"), transaction.price
    assert_equal BigDecimal("4.95"), transaction.fees
  end

  test "the round trip preserves the benchmark, kinds, notes and rule details" do
    seed_source_data!

    import_into(@target, export_for(@source))
    retirement = @target.portfolios.find_by!(name: "Retirement")

    assert_equal "S&P 500 (SPY)", retirement.benchmark.name
    assert_equal 1, retirement.transactions.where(kind: "dividend_reinvestment").count
    assert_equal "trimmed the position", retirement.transactions.find_by!(side: "sell").notes

    dollars = retirement.recurring_transactions.find_by!(amount_type: "dollars")
    assert_equal BigDecimal("250.5"), dollars.dollar_amount
    assert_equal "monthly", dollars.frequency

    shares = retirement.recurring_transactions.find_by!(amount_type: "shares")
    assert_equal BigDecimal("5.25"), shares.share_amount
    assert_equal Date.new(2130, 1, 1), shares.end_on
    assert_not shares.active, "a paused rule must not come back active"
  end

  test "the materialized transaction stays linked to its rule with its slot date" do
    seed_source_data!

    import_into(@target, export_for(@source))
    retirement = @target.portfolios.find_by!(name: "Retirement")
    rule = retirement.recurring_transactions.find_by!(amount_type: "dollars")
    materialized = retirement.transactions.find_by!(scheduled_for: Date.new(2124, 1, 31))

    assert_equal rule.id, materialized.recurring_transaction_id,
                 "losing this link lets the materializer duplicate an imported slot"
    # And the idempotency guard the link exists to serve still holds.
    duplicate = retirement.transactions.build(
      instrument: @aapl, side: "buy", shares: 1, price: 1, executed_on: Date.new(2124, 2, 1),
      recurring_transaction: rule, scheduled_for: Date.new(2124, 1, 31)
    )
    assert_not duplicate.valid?
  end

  test "a non-US instrument survives with its currency, type and sector" do
    seed_source_data!

    import_into(@target, export_for(@source))

    instrument = @target.portfolios.find_by!(name: "Taxable").transactions.sole.instrument
    assert_equal "ZEQT.TO", instrument.symbol
    assert_equal "CAD", instrument.currency
    assert_equal "etf", instrument.instrument_type
    assert_equal "Financials", instrument.sector
  end

  # --- Restoring into a genuinely empty database -------------------------------

  test "restores into an account with no instruments at all" do
    seed_source_data!
    payload = export_for(@source)

    # Simulate a rebuilt database: drop every instrument the import will need.
    # Benchmarks are seeded separately, so keep SPY's.
    @source.portfolios.destroy_all
    Instrument.where(id: [ @aapl.id, @zeqt.id ]).destroy_all
    assert_not Instrument.exists?([ "upper(symbol) = ?", "ZEQT.TO" ])

    result = import_into(@target, payload)

    assert_equal 0, result.totals[:portfolios_failed], result.portfolios.map(&:errors).inspect
    assert_equal 2, result.totals[:portfolios_created]
    assert_equal 5, result.totals[:transactions_created]
    assert_equal 2, result.totals[:recurring_created]
    assert_equal JSON.pretty_generate(payload), JSON.pretty_generate(export_for(@target))
  end

  # --- Re-importing into the SAME account is additive, never destructive -------

  test "re-importing into the same account renames instead of overwriting" do
    seed_source_data!
    payload = export_for(@source)
    original_transaction_count = @source.portfolios.find_by!(name: "Retirement").transactions.count

    result = import_into(@source, payload)

    assert_equal %w[renamed renamed], result.portfolios.map(&:status)
    assert_equal [ "Retirement", "Retirement (imported)", "Taxable", "Taxable (imported)" ],
                 @source.portfolios.order(:name).pluck(:name)
    assert_equal original_transaction_count,
                 @source.portfolios.find_by!(name: "Retirement").transactions.count,
                 "the original portfolio must be untouched by a re-import"
  end

  # --- Through the HTTP endpoints, not just the services -----------------------

  test "the round trip works end to end over HTTP" do
    seed_source_data!
    sign_in_as @source

    get export_api_v1_portfolios_path
    assert_response :ok
    downloaded = response.body

    sign_out
    sign_in_as @target
    post import_api_v1_portfolios_path,
         params: { file: Rack::Test::UploadedFile.new(StringIO.new(downloaded), "application/json",
                                                      original_filename: "export.json") }
    assert_response :ok
    report = JSON.parse(response.body).fetch("import")
    assert_equal 0, report.dig("totals", "portfolios_failed"), report.inspect
    assert_equal 2, report.dig("totals", "portfolios_created")

    get export_api_v1_portfolios_path
    assert_response :ok
    assert_equal JSON.parse(downloaded).except("exported_at"),
                 JSON.parse(response.body).except("exported_at"),
                 "the file downloaded from one account must re-export identically from another"
  end

  # --- Cash: the envelope's version 2 (issue #80) -------------------------------

  # The pre-#80 envelope, transcribed from the version-1 format. A no-cash export
  # must still produce these exact bytes: the only differences between the #80
  # exporter and its predecessor, for a portfolio with no cash rows, are the
  # version VALUE (the method returns 1 here, which is what the old constant was)
  # and a `cash_transactions` key that is OMITTED rather than written as []. Both
  # are no-ops for this fixture, so byte-identity is the assertion that proves it.
  #
  # If this literal ever needs editing to make the test pass, the export format
  # changed and every user's stored file just became a diff — which is the whole
  # reason it is spelled out here instead of being compared to itself.
  PRE_CASH_GOLDEN = <<~JSON.chomp
    {
      "format": "portfolioview.portfolios",
      "version": 1,
      "exported_at": "2026-03-04T00:00:00Z",
      "instruments": [
        {
          "symbol": "AAPL",
          "name": null,
          "instrument_type": "stock",
          "currency": "USD",
          "sector": null,
          "industry": null
        }
      ],
      "portfolios": [
        {
          "name": "Golden",
          "benchmark": null,
          "transactions": [
            {
              "symbol": "AAPL",
              "side": "buy",
              "kind": "normal",
              "shares": "10.0",
              "price": "150.25",
              "fees": "0.0",
              "executed_on": "2024-01-05",
              "notes": null,
              "recurring_key": null,
              "scheduled_for": null
            }
          ],
          "recurring_transactions": []
        }
      ]
    }
  JSON

  def golden_portfolio!(user)
    portfolio = create_portfolio(name: "Golden", user: user)
    buy!(portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "10", price: "150.25")
    portfolio
  end

  test "a NO-CASH export omits the cash key, stays at version 1, and is byte-identical" do
    golden_portfolio!(@source)

    payload = export_for(@source)

    assert_equal Portfolios::Transfer::NATIVE_VERSION_BASE, payload[:version]
    assert_not payload[:portfolios].first.key?(:cash_transactions),
               "an empty array here would bump every stored file into a diff for no gain"
    assert_equal PRE_CASH_GOLDEN, JSON.pretty_generate(payload)
    assert_not JSON.generate(payload).include?("cash"),
               "the word must not appear at all in a no-cash export"
  end

  test "a cash-bearing export carries version 2 and round-trips as a fixed point" do
    portfolio = create_portfolio(name: "Liquid", user: @source, benchmark: @benchmark)
    buy!(portfolio, @aapl, on: Date.new(2024, 2, 1), shares: "4", price: "100")
    # Every kind, both signs, including the two that are legitimately either:
    # a dividend reversal and a tax refund.
    cash!(portfolio, kind: "deposit", amount: "1000.50", on: Date.new(2024, 1, 15))
    cash!(portfolio, kind: "withdrawal", amount: "-250", on: Date.new(2024, 3, 1))
    cash!(portfolio, kind: "interest", amount: "0.07", on: Date.new(2024, 3, 2))
    cash!(portfolio, kind: "dividend_cash", amount: "-5.25", on: Date.new(2024, 3, 3),
          notes: "a reversal, and its sign is the information")
    cash!(portfolio, kind: "tax", amount: "3.10", on: Date.new(2024, 3, 4))
    cash!(portfolio, kind: "fee", amount: "-9.99", on: Date.new(2024, 3, 5))

    original = export_for(@source)
    assert_equal Portfolios::Transfer::NATIVE_VERSION_CASH, original[:version],
                 "a cash-bearing file must fail loudly on a build that cannot read cash"

    result = import_into(@target, original)
    assert_equal 0, result.totals[:portfolios_failed], result.portfolios.map(&:errors).inspect
    assert_equal 6, result.totals[:cash_created]

    assert_equal JSON.pretty_generate(original), JSON.pretty_generate(export_for(@target)),
                 "a round trip must be lossless"
  end

  test "the round trip preserves each cash amount's exact sign and scale" do
    portfolio = create_portfolio(name: "Liquid", user: @source)
    cash!(portfolio, kind: "dividend_cash", amount: "-5.25", on: Date.new(2024, 3, 3))
    cash!(portfolio, kind: "tax", amount: "3.10", on: Date.new(2024, 3, 4))

    import_into(@target, export_for(@source))

    rows = @target.portfolios.find_by!(name: "Liquid").cash_transactions.order(:occurred_on)
    assert_equal [ BigDecimal("-5.25"), BigDecimal("3.1") ], rows.map(&:amount),
                 "a negative dividend is a reversal and a positive tax is a refund"
    assert_equal %w[dividend_cash tax], rows.map(&:kind)
  end

  test "cash is exported sorted by (occurred_on, id) so two exports agree" do
    portfolio = create_portfolio(name: "Liquid", user: @source)
    cash!(portfolio, kind: "deposit", amount: "3", on: Date.new(2024, 3, 3))
    cash!(portfolio, kind: "deposit", amount: "1", on: Date.new(2024, 1, 1))
    # Two identical same-day deposits are two real bank transfers, so id breaks
    # the tie rather than the rows being deduped.
    cash!(portfolio, kind: "deposit", amount: "2", on: Date.new(2024, 3, 3))

    rows = export_for(@source)[:portfolios].first[:cash_transactions]

    assert_equal [ "1.0", "3.0", "2.0" ], rows.map { |r| r[:amount] }
    assert_equal JSON.generate(export_for(@source)), JSON.generate(export_for(@source))
  end

  test "a version-2 file is REFUSED by a build that only reads version 1" do
    portfolio = create_portfolio(name: "Liquid", user: @source)
    cash!(portfolio, kind: "deposit", amount: "1000", on: Date.new(2024, 1, 15))
    payload = export_for(@source)
    assert_equal 2, payload[:version]

    # The real gate, not a comment: an old build's SUPPORTED_VERSIONS. Refusing is
    # the only honest outcome — an old NativeParser would ignore the unknown
    # `cash_transactions` key and import a portfolio silently missing its money.
    error = stub_const(Portfolios::Transfer, :SUPPORTED_VERSIONS, [ 1 ].freeze) do
      assert_raises(Portfolios::Transfer::UnreadableFile) { import_into(@target, payload) }
    end

    assert_includes error.message, "has unsupported version 2"
    assert_includes error.message, "this build reads 1"
    assert_empty @target.portfolios
  end

  test "a version-1 file imports as a trade-basis portfolio, exactly as before" do
    create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 2, 29))
    seed_prices(@aapl, weekdays_between(Date.new(2024, 1, 1), Date.new(2024, 2, 29)).index_with { 150 })
    golden_portfolio!(@source)

    payload = export_for(@source)
    assert_equal 1, payload[:version]
    import_into(@target, payload)

    summary = Portfolios::Summary.call(portfolio: @target.portfolios.find_by!(name: "Golden"))

    assert_equal "trades", summary.deposit_basis
    assert_nil summary.cash_balance,
               "nil means “does not track cash”; 0.00 would claim it tracks cash and is flat"
  end

  # --- Analytics agree after a restore -----------------------------------------

  test "the restored portfolio values identically to the original" do
    # The point of a lossless export is that the DERIVED numbers agree too, not
    # just the rows.
    create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 6, 28))
    seed_prices(@aapl, weekdays_between(Date.new(2024, 1, 1), Date.new(2024, 6, 28)).index_with { 150 })

    source_portfolio = create_portfolio(name: "Valued", user: @source)
    buy!(source_portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "10", price: "150.25", fees: "4.95")
    sell!(source_portfolio, @aapl, on: Date.new(2024, 3, 1), shares: "2", price: "160")

    import_into(@target, export_for(@source))
    target_portfolio = @target.portfolios.find_by!(name: "Valued")

    original = Portfolios::Summary.call(portfolio: source_portfolio)
    restored = Portfolios::Summary.call(portfolio: target_portfolio)

    assert_equal original.current_value, restored.current_value
    assert_equal original.net_deposits, restored.net_deposits
    assert_equal original.total_return, restored.total_return
  end
end
