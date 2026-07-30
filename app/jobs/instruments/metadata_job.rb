module Instruments
  # Pulls the FMP company profile (sector / industry / type) once per new
  # instrument (docs/PLAN.md § Price pipeline / § Free data sources), cached
  # forever in Postgres with a monthly refresh (config/recurring.yml).
  #
  # Metadata is BEST-EFFORT: a missing profile, an exhausted FMP budget, or a
  # transient FMP failure must leave the instrument fully usable — no crash and,
  # crucially, no retry storm (the monthly refresh is the safety net). ETFs and
  # funds have no sector on the free tier; storing a nil sector is exactly how
  # the allocation code buckets them under "ETF / Fund" (Instrument#sector_label).
  class MetadataJob < ApplicationJob
    queue_as :default

    PROVIDER_NAME = "fmp".freeze

    discard_on ActiveRecord::RecordNotFound
    discard_on PriceProvider::ConfigurationError

    # Monthly refresh entry point (config/recurring.yml): re-fetch every
    # instrument's profile, forcing past the already-populated skip.
    def self.refresh_all
      Instrument.find_each { |instrument| perform_later(instrument.id, force: true) }
    end

    def perform(instrument_id, force: false)
      instrument = Instrument.find(instrument_id)
      return if !force && instrument.sector.present? # already classified; don't burn FMP quota

      PriceProvider::Budget.new(PROVIDER_NAME).charge!
      profile = provider.fetch_profile(instrument.symbol)
      return unless profile.found? # missing profile → leave the instrument usable

      instrument.update!(
        name: profile.name.presence || instrument.name,
        sector: profile.sector,       # nil for ETFs/funds → "ETF / Fund" downstream
        industry: profile.industry,
        instrument_type: profile.instrument_type.presence || instrument.instrument_type
      )

      # This is the ONLY moment a company name enters the system (issue #63):
      # the directory bulk file has no name column, so push it straight into
      # listed_instruments and the autocomplete gains a label with no extra
      # quota. Best-effort like the rest of this job — enrichment is cosmetic
      # and must never fail an otherwise-successful metadata fetch, so the
      # enqueue is guarded rather than trusted: a full queue or an adapter
      # error here would otherwise discard metadata already written above.
      begin
        Directory::EnrichNamesJob.perform_later
      rescue StandardError => e
        Rails.logger.warn("[#{self.class.name}] could not enqueue name enrichment (#{e.class.name}); " \
                          "the next directory import will re-apply it")
      end
    rescue PriceProvider::BudgetExceeded
      # Daily FMP budget spent — defer to the monthly refresh. No retry (a retry
      # today would just re-trip the same window).
      Rails.logger.warn("[#{self.class.name}] FMP budget exhausted for instrument=#{instrument_id}; deferring to monthly refresh")
    rescue PriceProvider::RateLimited, PriceProvider::ServerError, PriceProvider::MalformedResponse => e
      # Best-effort: swallow transient failures rather than storm the FMP tier.
      Rails.logger.warn("[#{self.class.name}] FMP transient failure for instrument=#{instrument_id} (#{e.class.name.demodulize}); skipping")
    rescue PriceProvider::UnknownSymbol
      Rails.logger.warn("[#{self.class.name}] FMP does not recognize instrument=#{instrument_id}; leaving unclassified")
    end

    private

    def provider = PriceProvider::Fmp.new
  end
end
