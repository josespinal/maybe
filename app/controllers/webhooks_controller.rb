class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  include BpdHelper

  def plaid
    webhook_body = request.body.read
    plaid_verification_header = request.headers["Plaid-Verification"]

    Provider::Plaid.validate_webhook!(plaid_verification_header, webhook_body)
    Provider::Plaid.process_webhook(webhook_body)

    render json: { received: true }, status: :ok
  rescue => error
    render json: { error: "Invalid webhook: #{error.message}" }, status: :bad_request
  end

  def stripe
    webhook_body = request.body.read
    sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
    client = Stripe::StripeClient.new(ENV["STRIPE_SECRET_KEY"])

    begin
      thin_event = client.parse_thin_event(webhook_body, sig_header, ENV["STRIPE_WEBHOOK_SECRET"])

      event = client.v1.events.retrieve(thin_event.id)

      case event.type
      when /^customer\.subscription\./
        handle_subscription_event(event)
      when "customer.created", "customer.updated", "customer.deleted"
        handle_customer_event(event)
      else
        Rails.logger.info "Unhandled event type: #{event.type}"
      end

    rescue JSON::ParserError
      render json: { error: "Invalid payload" }, status: :bad_request
      return
    rescue Stripe::SignatureVerificationError
      render json: { error: "Invalid signature" }, status: :bad_request
      return
    end

    render json: { received: true }, status: :ok
  end

  def bpd_notification
    # Verify the Mailgun signature (optional but recommended)
    if valid_signature?(params[:timestamp], params[:token], params[:signature])
      # Process the email data
      from = params[:from]
      subject = params[:subject]
      body_html = params["body-html"]

      # Handle your logic here
      Rails.logger.info "Received email from: #{from}, Subject: #{subject}"
      Rails.logger.info "Body: #{body_html}"

      parsed_data = parse_email_content(body_html)

      Rails.logger.info "Parsed data: #{parsed_data}"
      Rails.logger.info "Monto: #{parsed_data["Monto"]}"
      Rails.logger.info "Comercio: #{parsed_data["Comercio"]}"
      Rails.logger.info "Comercio: #{parsed_data["Last 4 Digits"]}"
      Rails.logger.info "Fecha: #{Date.strptime(parsed_data["Fecha"], "%d/%m/%Y").strftime("%Y-%m-%d")}"

      # account = Account.find_by("name LIKE ?", "%#{parsed_data['Moneda'] #{parsed_data['Last 4 Digits']}")
      # transaction = Account::Transaction.new(
      #   category: Category.find_by(name: "Sin Asignar"), # Replace with the actual category ID
      #   merchant: Merchant.find_or_create_by(name: parsed_data["Comercio"]),
      # )

      # entry = Account::Entry.create!(
      #   account: account,
      #   name: parsed_data["Comercio"] + " - " + parsed_data["Fecha"],
      #   date: Date.strptime(parsed_data["Fecha"], "%d/%m/%Y").strftime("%Y-%m-%d"),
      #   currency: parsed_data["Moneda"],
      #   amount: -parsed_data["Monto"],
      #   entryable: transaction
      # )

      # Rails.logger.info "Entry created: #{entry.inspect}"

      # Respond with success
      head :ok
    else
      render json: { error: "Invalid signature" }, status: :unauthorized
    end
  end

  private

    def handle_subscription_event(event)
      subscription = event.data.object
      family = Family.find_by(stripe_customer_id: subscription.customer)

      if family
        family.update(
          stripe_plan_id: subscription.plan.id,
          stripe_subscription_status: subscription.status
        )
      else
        Rails.logger.error "Family not found for Stripe customer ID: #{subscription.customer}"
      end
    end

    def handle_customer_event(event)
      customer = event.data.object
      family = Family.find_by(stripe_customer_id: customer.id)

      if family
        family.update(stripe_customer_id: customer.id)
      else
        Rails.logger.error "Family not found for Stripe customer ID: #{customer.id}"
      end
    end
end
