module BpdHelper
  require "nokogiri"

  def parse_email_content(body_html)
    doc = Nokogiri::HTML(body_html)

    # Locate the transaction table (first table containing 'Monto')
    table = doc.xpath('//table[contains(@style, "max-width:80%")]').first
    
    # Locate the othe possible format of table
    unless table
      table = doc.at_css("table.myTable2")
    end

    return {} unless table

    # Extract headers (inside <th> tags)
    headers = table.xpath(".//tr[1]/th").map { |th| th.text.strip }

    # Extract values (inside <td> tags from the first data row beneath headers)
    # Use a more specific XPath to target the correct row
    first_row = table.xpath(".//tr[2]/td").map { |td| td.text.strip }
    return {} if first_row.empty?

    # Debug: Print headers and first row
    # puts "Headers: #{headers.inspect}"
    # puts "First Row: #{first_row.inspect}"

    return {} if first_row.empty?

    # Map headers to row values
    transaction = headers.zip(first_row).to_h

    
    parse_monto(transaction)
    card_info = extract_card_info(doc)
    transaction.merge!(card_info)
    
    # Debug: Print transaction hash
    # puts "Transaction: #{transaction.inspect}"
    
    transaction
  end

  private

    # Parses "Monto" and detects currency
    def parse_monto(transaction)
      return unless transaction["Monto"]

      # Detect currency based on prefix
      transaction["Moneda"] =
        if transaction["Monto"].include?("RD$")
          "DOP"
        elsif transaction["Monto"].include?("US$")
          "USD"
        elsif transaction["Monto"].include?("EUR$")
          "EUR"
        else
          "Unknown"
        end

      # Remove currency symbols, commas, and convert to a float
      transaction["Monto"] = transaction["Monto"].gsub(/[^\d.]/, "").to_f
    end

    # Extract card type and last 4 digits
    def extract_card_info(doc)
      card_text = doc.at_css('p:contains("Gracias por utilizar su")')&.text

      return {} unless card_text

      if (match = card_text.match(/Gracias por utilizar su\s+([A-Za-z\s]+),\s+terminada en\s+(\d{4})/))
        {
          "Card Type" => match[1]&.strip,
          "Last 4 Digits" => match[2]&.strip
        }
      else
        {}
      end
    end

    def verify_mailgun_signature(params)
      return true

      token = params[:token]
      timestamp = params[:timestamp]
      signature = params[:signature]

      # Ensure the timestamp is recent to prevent replay attacks
      if timestamp.to_i < Time.now.to_i - 15 * 60
        return false
      end

      # Generate the expected signature
      data = [ timestamp, token ].join
      expected_signature = OpenSSL::HMAC.hexdigest(
        OpenSSL::Digest::SHA256.new,
        ENV["MAILGUN_SIGNING_KEY"],
        data
      )

      ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature)
    end

    # Save a transaction to the database
    def save_transaction(transaction, email)
      Transaction.create!(
        amount: Money.new(transaction["Monto"], transaction["Moneda"]),
        type: transaction["Estatus"],
        currency: transaction["Moneda"],
        date_posted: transaction["Fecha"],
        time_posted: email.date.strftime("%H:%M:%S"),
        merchant_name: transaction["Comercio"],
        card_type: transaction["Card Type"],
        last_4_digits: transaction["Last 4 Digits"],
        notes: transaction["Estatus"]
      )
    end
end
