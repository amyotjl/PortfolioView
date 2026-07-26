module Api
  module V1
    # Portfolio export / import (backlog #064, issue #64).
    #
    #   GET  /api/v1/portfolios/export[?portfolio_ids[]=1&portfolio_ids[]=2]
    #   POST /api/v1/portfolios/import   (multipart: file, on_conflict, dry_run)
    #
    # Export answers a JSON body with Content-Disposition: attachment, so the SPA
    # can save it straight to disk. Import accepts either the native export
    # envelope or a broker holdings CSV — the format is sniffed from the file's
    # CONTENT (Portfolios::Transfer::Detector), never from its name or the
    # browser-supplied MIME type.
    #
    # Everything is scoped to Current.user: export can only ever read the current
    # user's portfolios, and import can only ever write to their account.
    class PortfolioTransfersController < BaseController
      # An unreadable file is USER INPUT being wrong, not the server breaking —
      # 422 keyed on the `file` field so the upload dialog can render it inline.
      rescue_from Portfolios::Transfer::UnreadableFile do |error|
        render_error(
          code: "validation_failed",
          message: "The uploaded file could not be read.",
          status: :unprocessable_entity,
          details: { file: [ "#{error.message}" ] }
        )
      end

      # GET /api/v1/portfolios/export
      def export
        exporter = Portfolios::Transfer::Export.new(
          user: Current.user,
          portfolio_ids: export_portfolio_ids
        )

        send_data JSON.pretty_generate(exporter.call),
                  type: "application/json",
                  disposition: "attachment",
                  filename: exporter.filename
      end

      # POST /api/v1/portfolios/import
      def import
        body = read_upload
        return if performed?

        document = Portfolios::Transfer::Detector.new(body).parser.call(body)
        result = Portfolios::Transfer::Import.call(
          user: Current.user,
          document: document,
          on_conflict: params[:on_conflict].presence || "rename",
          dry_run: params[:dry_run]
        )

        render json: { import: PortfolioImportSerializer.new(result).as_json }
      end

      private

      # Optional subset filter. Non-integer entries are dropped rather than
      # rejected — `?portfolio_ids[]=` from an empty multi-select is not an error,
      # and ids the user doesn't own are already excluded by the user-owned scope.
      def export_portfolio_ids
        ids = Array(params[:portfolio_ids]).map { |id| Integer(id, exception: false) }.compact
        ids.presence
      end

      # Reads the upload into memory, enforcing the byte cap BEFORE the parsers
      # see anything. Renders the 422 envelope and returns nil on any problem, so
      # the caller must check `performed?`.
      def read_upload
        file = params[:file]

        unless file.respond_to?(:read)
          render_file_error("is required")
          return nil
        end

        # Trust the reported size only as a fast reject; the authoritative check is
        # on the bytes actually read, since size can be absent or wrong.
        if file.respond_to?(:size) && file.size.to_i > Portfolios::Transfer::MAX_FILE_BYTES
          render_file_error(too_large_message)
          return nil
        end

        body = file.read.to_s
        if body.bytesize > Portfolios::Transfer::MAX_FILE_BYTES
          render_file_error(too_large_message)
          return nil
        end

        if body.strip.empty?
          render_file_error("is empty")
          return nil
        end

        # Uploads arrive as ASCII-8BIT; the parsers do String matching and CSV
        # parsing, both of which need a real encoding. scrub away invalid bytes so
        # a mis-encoded file yields a parse error rather than an EncodingError 500.
        body.force_encoding(Encoding::UTF_8).scrub("")
      end

      def too_large_message
        "must be smaller than #{Portfolios::Transfer::MAX_FILE_BYTES / (1024 * 1024)} MB"
      end

      def render_file_error(message)
        render_error(
          code: "validation_failed",
          message: "Validation failed.",
          status: :unprocessable_entity,
          details: { file: [ message ] }
        )
      end
    end
  end
end
