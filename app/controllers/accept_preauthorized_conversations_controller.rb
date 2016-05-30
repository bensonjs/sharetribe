class AcceptPreauthorizedConversationsController < ApplicationController

  before_filter do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_accept_or_reject")
  end

  before_filter :fetch_conversation
  before_filter :fetch_listing

  before_filter :ensure_is_author

  # Skip auth token check as current jQuery doesn't provide it automatically
  skip_before_filter :verify_authenticity_token

  MessageForm = Form::Message

  def accept
    tx_id = params[:id]
    tx = TransactionService::API::Api.transactions.query(tx_id)

    if tx[:current_state] != :preauthorized
      redirect_to person_transaction_path(person_id: @current_user.id, id: tx_id)
      return
    end

    payment_type = tx[:payment_gateway]
    case payment_type
    when :braintree
      render_braintree_form("accept")
    when :paypal
      render_paypal_form("accept")
    else
      raise ArgumentError.new("Unknown payment type: #{payment_type}")
    end
  end

  def reject
    tx_id = params[:id]
    tx = TransactionService::API::Api.transactions.query(tx_id)

    if tx[:current_state] != :preauthorized
      redirect_to person_transaction_path(person_id: @current_user.id, id: tx_id)
      return
    end

    payment_type = tx[:payment_gateway]
    case payment_type
    when :braintree
      render_braintree_form("reject")
    when :paypal
      render_paypal_form("reject")
    else
      raise ArgumentError.new("Unknown payment type: #{payment_type}")
    end
  end

  def accepted_or_rejected
    tx_id = params[:id]
    message = params[:listing_conversation][:message_attributes][:content]
    status = params[:listing_conversation][:status].to_sym
    sender_id = @current_user.id

    tx = TransactionService::API::Api.transactions.query(tx_id)

    if tx[:current_state] != :preauthorized
      redirect_to person_transaction_path(person_id: @current_user.id, id: tx_id)
      return
    end

    res = accept_or_reject_tx(@current_community.id, tx_id, status, message, sender_id)

    if res[:success]
      flash[:notice] = success_msg(res[:flow])
      redirect_to person_transaction_path(person_id: sender_id, id: tx_id)
    else
      flash[:error] = error_msg(res[:flow])
      redirect_to accept_preauthorized_person_message_path(person_id: sender_id , id: tx_id)
    end
  end

  def complete
    binding.pry
    conversation =      MarketplaceService::Conversation::Query.conversation_for_person(@listing_conversation.conversation.id, @current_user.id, @current_community.id)
    can_be_confirmed =  MarketplaceService::Transaction::Query.can_transition_to?(@listing_conversation, :completed)
    other_person =      query_person_entity(@listing_conversation.other_party(@current_user).id)

    render(locals: {
      action_type: "complete",
      message_form: MessageForm.new,
      listing_transaction: @listing_conversation,
      can_be_confirmed: can_be_confirmed,
      other_person: other_person,
      status: "paid",
      form: @listing_conversation, # TODO fix me, don't pass objects
      form_action: completion_preauthorized_person_message_path(
        person_id: @current_user.id,
        id: @listing_conversation.id
      )
    })
  end

  def completed_or_rejected
    binding.pry
    tx_id = params[:id]
    status = params[:listing_conversation][:status].to_sym
    sender_id = @current_user.id
    tx = TransactionService::API::Api.transactions.query(tx_id)

    if tx[:current_state] != :confirmed
      redirect_to person_transaction_path(person_id: @current_user.id, id: tx_id)
      return
    end

    res = completed_or_rejected_tx(@current_community.id, tx_id, status, sender_id)

    if res[:success]
      flash[:notice] = success_msg(res[:flow])
      redirect_to person_transaction_path(person_id: sender_id, id: tx_id)
    else
      flash[:error] = error_msg(res[:flow])
      redirect_to complete_preauthorized_person_message_path(person_id: sender_id , id: tx_id)
    end
  end

  private

  def accept_or_reject_tx(community_id, tx_id, status, message, sender_id)
    if (status == :paid)
      accept_tx(community_id, tx_id, message, sender_id)
    elsif (status == :rejected)
      reject_tx(community_id, tx_id, message, sender_id)
    else
      {flow: :unknown, success: false}
    end
  end

  def accept_tx(community_id, tx_id, message, sender_id)
    TransactionService::Transaction.complete_preauthorization(community_id: community_id,
                                                              transaction_id: tx_id,
                                                              message: message,
                                                              sender_id: sender_id)
      .maybe()
      .map { |_| {flow: :accept, success: true}}
      .or_else({flow: :accept, success: false})
  end

  def reject_tx(community_id, tx_id, message, sender_id)
    TransactionService::Transaction.reject(community_id: community_id,
                                           transaction_id: tx_id,
                                           message: message,
                                           sender_id: sender_id)
      .maybe()
      .map { |_| {flow: :reject, success: true}}
      .or_else({flow: :reject, success: false})
  end

  def completed_or_rejected_tx(community_id, tx_id, status, sender_id)
    if (status == :completed)
      complete_confirmation_tx(community_id, tx_id, sender_id)
    elsif (status == :rejected)
      reject_complete_tx(community_id, tx_id, sender_id)
    else
      {flow: :unknown, success: false}
    end
  end

  def complete_confirmation_tx(community_id, tx_id, sender_id)
    binding.pry
    TransactionService::Transaction.complete_confirmation(community_id: community_id,
                                                              transaction_id: tx_id,
                                                              sender_id: sender_id)
      .maybe()
      .map { |_| {flow: :accept, success: true}}
      .or_else({flow: :accept, success: false})
  end

  def reject_complete_tx(community_id, tx_id, sender_id)
    # TODO - reject_complete_tx
  end

  def success_msg(flow)
    if flow == :accept
      t("layouts.notifications.request_accepted")
    elsif flow == :complete
      t("layouts.notifications.transaction_completed")
    elsif flow == :reject
      t("layouts.notifications.request_rejected")
    end
  end

  def error_msg(flow)
    if flow == :accept
      t("error_messages.paypal.accept_authorization_error")
    elsif flow == :reject
      t("error_messages.paypal.reject_authorization_error")
    end
  end

  def ensure_is_author
    unless @listing.author == @current_user
      flash[:error] = "Only listing author can perform the requested action"
      redirect_to (session[:return_to_content] || root)
    end
  end

  def fetch_listing
    @listing = @listing_conversation.listing
  end

  def fetch_conversation
    @listing_conversation = @current_community.transactions.find(params[:id])
  end

  def render_paypal_form(preselected_action)
    transaction_conversation = MarketplaceService::Transaction::Query.transaction(@listing_conversation.id)
    result = TransactionService::Transaction.get(community_id: @current_community.id, transaction_id: @listing_conversation.id)
    transaction = result[:data]
    community_country_code = LocalizationUtils.valid_country_code(@current_community.country)
binding.pry
    render "accept", locals: {
      payment_gateway: :paypal,
      listing: @listing,
      listing_quantity: transaction[:listing_quantity],
      booking: transaction[:booking],
      orderer: @listing_conversation.starter,
      sum: transaction[:item_total],
      fee: transaction[:commission_total],
      shipping_price: transaction[:shipping_price],
      shipping_address: transaction[:shipping_address],
      deposit: transaction[:deposit],
      seller_gets: transaction[:checkout_total] - transaction[:commission_total] - transaction[:deposit],
      form: @listing_conversation, # TODO FIX ME, DONT USE MODEL
      form_action: acceptance_preauthorized_person_message_path(
        person_id: @current_user.id,
        id: @listing_conversation.id
      ),
      preselected_action: preselected_action,
      paypal_fees_url: PaypalCountryHelper.fee_link(community_country_code)
    }
  end

  def render_braintree_form(preselected_action)
    result = TransactionService::Transaction.get(community_id: @current_community.id, transaction_id: @listing_conversation.id)
    transaction = result[:data]

    render action: :accept, locals: {
      payment_gateway: :braintree,
      listing: @listing,
      listing_quantity: transaction[:listing_quantity],
      booking: transaction[:booking],
      orderer: @listing_conversation.starter,
      sum: transaction[:item_total],
      fee: transaction[:commission_total],
      shipping_price: nil,
      shipping_address: nil,
      seller_gets: transaction[:checkout_total] - transaction[:commission_total],
      form: @listing_conversation,
      form_action: acceptance_preauthorized_person_message_path(
        person_id: @current_user.id,
        id: @listing_conversation.id
      ),
      preselected_action: preselected_action
    }
  end

  def query_person_entity(id)
    person_entity = MarketplaceService::Person::Query.person(id, @current_community.id)
    person_display_entity = person_entity.merge(
      display_name: PersonViewUtils.person_entity_display_name(person_entity, @current_community.name_display_type)
    )
  end
end
