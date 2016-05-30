module PaypalService::API

  class Payments

    # Include with_success for wrapping requests and responses
    include RequestWrapper

    attr_reader :logger

    MerchantData = PaypalService::DataTypes::Merchant
    AdaptivePaymentsData = PaypalService::DataTypes::AdaptivePayments
    TokenStore = PaypalService::Store::Token
    PaymentStore = PaypalService::Store::PaypalPayment
    AccountStore = PaypalService::Store::PaypalAccount
    TxStore = TransactionService::Store::Transaction
    Lookup = PaypalService::API::Lookup
    Worker = PaypalService::API::Worker
    Invnum = PaypalService::API::Invnum
    APIDataTypes = PaypalService::API::DataTypes

    def initialize(events, merchant, logger = PaypalService::Logger.new)
      @logger = logger
      @events = events
      @merchant = merchant
      @lookup = Lookup.new(logger)
    end

    # For RequestWrapper mixin
    def paypal_merchant
      @merchant
    end


    # The API implementation
    #

    ## POST /payments/request
    def request(community_id, create_payment, async: false)
      @lookup.with_active_account(
        community_id, create_payment[:merchant_id]
      ) do |m_acc|
        if (async)
          proc_token = Worker.enqueue_payments_op(
            community_id: community_id,
            transaction_id: create_payment[:transaction_id],
            op_name: :do_request,
            op_input: [community_id, create_payment, m_acc])

          proc_status_response(proc_token)
        else
          do_request(community_id, create_payment, m_acc)
        end
      end
    end

    def do_request(community_id, create_payment, m_acc)
      binding.pry
      create_payment_data = create_payment.merge(
        { receiver_username: m_acc[:payer_id],
          invnum: Invnum.create(community_id, create_payment[:transaction_id], :payment)})
      request =
        if (create_payment[:payment_action] == :order)
          MerchantData.create_set_express_checkout_order(create_payment_data)
        else
          MerchantData.create_set_preapproval(create_payment_data)
          # MerchantData.create_set_pay(create_payment_data)
          # AdaptivePaymentsData.create_set_pay(create_payment_data)
          # MerchantData.create_set_express_checkout_authorization(create_payment_data)
        end

      with_success(community_id, create_payment[:transaction_id],
        request,
        error_policy: {
          codes_to_retry: ["10001", "x-timeout", "x-servererror"],
          try_max: 3
        }
      ) do |response|
        TokenStore.create({
          community_id: community_id,
          token: response[:token],
          transaction_id: create_payment[:transaction_id],
          payment_action: create_payment[:payment_action],
          merchant_id: m_acc[:person_id],
          receiver_id: m_acc[:payer_id],
          item_name: create_payment[:item_name],
          item_quantity: create_payment[:item_quantity],
          item_price: create_payment[:item_price] || create_payment[:order_total],
          order_total: create_payment[:order_total],
          shipping_total: create_payment[:shipping_total],
          express_checkout_url: response[:redirect_url]
        })

        Result::Success.new(
          APIDataTypes.create_payment_request({
              transaction_id: create_payment[:transaction_id],
              token: response[:token],
              redirect_url: response[:redirect_url]}))
      end
    end

    def get_request_token(community_id, token)
      @lookup.with_token(community_id, token) do |token|
        Result::Success.new(token)
      end
    end

    ## POST /payments/request/cancel?token=EC-7XU83376C70426719
    def request_cancel(community_id, token_id)
      token = TokenStore.get(community_id, token_id)
      unless (token.nil?)
        TokenStore.delete(community_id, token[:transaction_id])

        #trigger callback for request cancelled
        @events.send(:request_cancelled, :success, token)

        Result::Success.new
      else
        #Handle errors by logging, because request cancellations are async (direct cancels + scheduling)
        @logger.warn("Tried to cancel non-existent request: [token: #{token_id}, community: #{community_id}]")
        Result::Error.new("Tried to cancel non-existent request: [token: #{token_id}, community: #{community_id}]")
      end
    end

    ## POST /payments/:community_id/create?token=EC-7XU83376C70426719
    def create(community_id, token, async: false)
      binding.pry
      @lookup.with_token(community_id, token) do |token|
        if (async)
          proc_token = Worker.enqueue_payments_op(
            community_id: community_id,
            transaction_id: token[:transaction_id],
            op_name: :do_create,
            op_input: [community_id, token])

          proc_status_response(proc_token)
        else
          do_create(community_id, token)
        end
      end
    end

    def do_create(community_id, token)
      binding.pry
      existing_payment = @lookup.get_payment_by_token(token)

      response =
        if existing_payment.nil?
          create_payment(token)
            .and_then { |payment_entity| ensure_payment_authorized(community_id, payment_entity) }
        else
          ensure_payment_authorized(community_id, existing_payment)
        end

      if response.success
        # Delete the token, we have now completed the payment request
        TokenStore.delete(community_id, response[:data][:transaction_id])
      end
binding.pry
      response
    end

    def ensure_payment_authorized(community_id, payment_entity)
      if payment_entity[:pending_reason] == :"payment-review"
        Result::Error.new("Cannot complete authorization because the payment is pending for manual review by PayPal.",
                          { error_code: :"payment-review", payment: payment_entity })
      elsif payment_entity[:pending_reason] != :authorization
        authorize_payment(community_id, payment_entity)
      else
        Result::Success.new(payment_entity)
      end
    end


    ## POST /payments/:community_id/:transaction_id/full_capture
    def full_capture(community_id, transaction_id, info, async: false)
      @lookup.with_payment(community_id, transaction_id, [[:pending, :authorization]]) do |payment, m_acc|
        if (async)
          proc_token = Worker.enqueue_payments_op(
            community_id: community_id,
            transaction_id: transaction_id,
            op_name: :do_full_capture,
            op_input: [community_id, transaction_id, info, payment, m_acc])

          proc_status_response(proc_token)
        else
          do_full_capture(community_id, transaction_id, info, payment, m_acc)
        end
      end
    end
    
    def do_full_capture(community_id, transaction_id, info, payment, m_acc)
    binding.pry
        admin_acc = AccountStore.get_active(community_id: community_id)
        tx = TxStore.get(transaction_id)
        total_price = tx[:unit_price] * tx[:listing_quantity]
        commission_total = TransactionService::Transaction.calculate_commission(total_price, tx[:commission_from_seller], tx[:minimum_commission])

      with_success(community_id, transaction_id,
        MerchantData.create_set_pay({
            receiver_username: m_acc[:payer_id],
            primary_receiver: admin_acc[:email],
            receiver: m_acc[:email],
            preapprovalKey: payment[:authorization_id],
            order_total: total_price - commission_total,
            primary_total: tx[:deposit] + commission_total,
            success: "https://test.com/adaptive_payments/pay",
            cancel: "https://test.com/adaptive_payments/pay",
            invnum: Invnum.create(community_id, transaction_id, :payment)
          }),
        error_policy: {
          codes_to_retry: ["10001", "x-timeout", "x-servererror"],
          try_max: 5,
          finally: (method :void_failed_payment).call(payment, m_acc)
        }
        ) do |payment_res|

binding.pry
        # Save payment data to payment
        payment = PaymentStore.update(
          data: payment_res,
          community_id: community_id,
          transaction_id: transaction_id
         )
binding.pry
        payment_entity = DataTypes.create_payment(payment)

        # Trigger payment_updated event
        @events.send(:payment_updated, :success, payment_entity)

        # Return as payment entity
        Result::Success.new(payment_entity)
      end
    end

    def do_full_capture_bak(community_id, transaction_id, info, payment, m_acc)
      binding.pry
      with_success(community_id, transaction_id,
        MerchantData.create_do_full_capture({
            receiver_username: m_acc[:payer_id],
            authorization_id: payment[:authorization_id],
            payment_total: info[:payment_total],
            invnum: Invnum.create(community_id, transaction_id, :payment)
          }),
        error_policy: {
          codes_to_retry: ["10001", "x-timeout", "x-servererror"],
          try_max: 5,
          finally: (method :void_failed_payment).call(payment, m_acc)
        }
        ) do |payment_res|

        # Save payment data to payment
        payment = PaymentStore.update(
          data: payment_res,
          community_id: community_id,
          transaction_id: transaction_id
         )

        payment_entity = APIDataTypes.create_payment(payment)

        # Trigger payment_updated event
        @events.send(:payment_updated, :success, payment_entity)

        # Return as payment entity
        Result::Success.new(payment_entity)
      end
    end

    ## GET /payments/:community_id/:transaction_id
    def get_payment(community_id, transaction_id)
      Maybe(PaymentStore.get(community_id, transaction_id))
        .map { |payment| Result::Success.new(APIDataTypes.create_payment(payment)) }
        .or_else { Result::Error.new("No matching payment for community_id: #{community_id} and transaction_id: #{transaction_id}.")}
    end

    ## POST /payments/:community_id/:transaction_id/void
    def void(community_id, transaction_id, info, async: false)
      @lookup.with_payment(community_id, transaction_id, [[:pending, nil]]) do |payment, m_acc|
        if (async)
          proc_token = Worker.enqueue_payments_op(
            community_id: community_id,
            transaction_id: transaction_id,
            op_name: :do_void,
            op_input: [community_id, transaction_id, info, payment, m_acc])

          proc_status_response(proc_token)
        else
          do_void(community_id, transaction_id, info, payment, m_acc)
        end
      end
    end

    def do_void(community_id, transaction_id, info, payment, m_acc)
      void_payment(
        community_id,
        transaction_id,
        payment,
        :success,
        m_acc,
        info[:note])
    end

    ## POST /payments/:community_id/:transaction_id/refund
    def refund(community_id, transaction_id)
      raise NoMethodError.new("Not implemented")
    end

    ## Not part of the public API, used by rake task to retry and clean unfinished orders
    def retry_and_clean_tokens(clean_time_limit)
      TokenStore.get_all.each do |token|
        response = create(token.community_id, token.token)

        if(!response[:success] && stop_retrying_token?(response, token.created_at, clean_time_limit))
          request_cancel(token.community_id, token.token)
        end
      end
    end

    def return_deposit(community_id, transaction_id, info, async: false)
      @lookup.with_payment(community_id, transaction_id, [[:completed]]) do |payment, m_acc|
        if (async)
          proc_token = Worker.enqueue_payments_op(
            community_id: community_id,
            transaction_id: transaction_id,
            op_name: :do_full_capture,
            op_input: [community_id, transaction_id, info, payment, m_acc])

          proc_status_response(proc_token)
        else
          do_return_deposit(community_id, transaction_id, info, payment, m_acc)
        end
      end
    end

    def do_return_deposit(community_id, transaction_id, info, payment, m_acc)
    binding.pry
        admin_acc = AccountStore.get_active(community_id: community_id)
        tx = TxStore.get(transaction_id)
        total_price = tx[:unit_price] * tx[:listing_quantity]

      with_success(community_id, transaction_id,
        MerchantData.create_return_deposit({
            payKey: payment[:authorization_id],
            primary_receiver: admin_acc[:email],
            deposit_total: tx[:deposit],
            success: "https://test.com/adaptive_payments/pay",
            cancel: "https://test.com/adaptive_payments/pay",
            invnum: Invnum.create(community_id, transaction_id, :payment)
          }),
        error_policy: {
          codes_to_retry: ["10001", "x-timeout", "x-servererror"],
          try_max: 5,
          finally: (method :void_failed_payment).call(payment, m_acc)
        }
        ) do |payment_res|

binding.pry
        # Save payment data to payment
        payment = PaymentStore.update(
          data: payment_res,
          community_id: community_id,
          transaction_id: transaction_id
         )
binding.pry
        payment_entity = DataTypes.create_payment(payment)

        # Trigger payment_updated event
        @events.send(:payment_updated, :success, payment_entity)

        # Return as payment entity
        Result::Success.new(payment_entity)
      end
    end


    private


    # Reusable bits of the API operations
    #

    def stop_retrying_token?(response, token_created_at, clean_time_limit)
      if (token_created_at < clean_time_limit && (response[:data] == nil || response[:data][:error_code] != :"payment-review"))
        true
      else
        false
      end
    end
    
    def create_payment(token)
      @lookup.with_merchant_account(token[:community_id], token) do |m_acc|
        # Save payment
        binding.pry
          payment = PaymentStore.create(
            token[:community_id],
            token[:transaction_id],
            {receiver_id: m_acc[:payer_id], merchant_id: m_acc[:person_id], payer_id: m_acc[:payer_id], 
              authorization_total: token[:order_total], currency: token[:order_total].currency.iso_code, payment_status: "pending", pending_reason: token[:payment_action].to_s,
              authorization_id: token[:token], authorization_date: Time.new}
          )

          payment_entity = DataTypes.create_payment(payment)

          # Send event payment_crated
          @events.send(:payment_created, :success, payment_entity)

          # Return as payment entity
          Result::Success.new(payment_entity)
      end
    end

    def create_payment_bak(token)
      @lookup.with_merchant_account(token[:community_id], token) do |m_acc|
        with_success(token[:community_id], token[:transaction_id],
          MerchantData.create_get_express_checkout_details(
            { receiver_username: m_acc[:payer_id], token: token[:token] }
          ),
          error_policy: {
            codes_to_retry: ["10001", "x-timeout", "x-servererror"],
            try_max: 3,
            finally: method(:handle_failed_create_payment).call(token),
          }
        ) do |ec_details|
          # Validate that the buyer accepted and we have a payer_id now
          if (ec_details[:payer_id].nil?)
            return Result::Error.new("Payment has not been accepted by the buyer.")
          end

binding.pry
          order_details = create_order_details(ec_details)
                          .merge({community_id: token[:community_id], transaction_id: token[:transaction_id]})
                          binding.pry
          @events.send(:order_details, :success, order_details)
binding.pry
          with_success(token[:community_id], token[:transaction_id],
            MerchantData.create_do_express_checkout_payment({
              payment_action: token[:payment_action],
              receiver_username: m_acc[:payer_id],
              token: token[:token],
              payer_id: ec_details[:payer_id],
              order_total: ec_details[:order_total],
              item_name: token[:item_name],
              item_quantity: token[:item_quantity],
              item_price: token[:item_price],
              shipping_total: token[:shipping_total],
              shipping_address_city: ec_details[:shipping_address_city],
              shipping_address_country_code: ec_details[:shipping_address_country_code],
              shipping_address_name: ec_details[:shipping_address_name],
              shipping_address_phone: ec_details[:shipping_address_phone],
              shipping_address_postal_code: ec_details[:shipping_address_postal_code],
              shipping_address_state_or_province: ec_details[:shipping_address_state_or_province],
              shipping_address_street1: ec_details[:shipping_address_street1],
              shipping_address_street2: ec_details[:shipping_address_street2],
              invnum: Invnum.create(token[:community_id], token[:transaction_id], :payment)
            }),
            error_policy: {
              codes_to_retry: ["10001", "x-timeout", "x-servererror"],
              try_max: 3,
              finally: (method :handle_failed_create_payment).call(token)
            }
          ) do |payment_res|
binding.pry
            # Save payment
            payment = PaymentStore.create(
              token[:community_id],
              token[:transaction_id],
              ec_details
                .merge(payment_res)
                .merge({receiver_id: m_acc[:payer_id], merchant_id: m_acc[:person_id]})
            )

            payment_entity = APIDataTypes.create_payment(payment)

            # Send event payment_crated
            @events.send(:payment_created, :success, payment_entity)

            # Return as payment entity
            Result::Success.new(payment_entity)
          end
        end
      end
    end

    def create_order_details(data)
      APIDataTypes.create_order_details(
        HashUtils.rename_keys({
          shipping_address_status: :status,
          shipping_address_city: :city,
          shipping_address_country: :country,
          shipping_address_country_code: :country_code,
          shipping_address_name: :name,
          shipping_address_phone: :phone,
          shipping_address_postal_code: :postal_code,
          shipping_address_state_or_province: :state_or_province,
          shipping_address_street1: :street1,
          shipping_address_street2: :street2,
        }, data))
    end

    def authorize_payment(community_id, payment)
      @lookup.with_payment(community_id, payment[:transaction_id], [[:pending, :order]]) do |payment, m_acc|
        with_success(community_id, payment[:transaction_id],
          MerchantData.create_do_authorization({
              receiver_username: m_acc[:payer_id],
              order_id: payment[:order_id],
              authorization_total: payment[:order_total]
          }),
          error_policy: {
            codes_to_retry: ["10001", "x-timeout", "x-servererror"],
            try_max: 5,
            finally: (method :handle_failed_authorization).call(payment, m_acc)
          }
        ) do |auth_res|

          # Save authorization data to payment
          payment = PaymentStore.update(data: auth_res, community_id: community_id , transaction_id: payment[:transaction_id])
          payment_entity = APIDataTypes.create_payment(payment)

          # Trigger callback for authorized
          @events.send(:payment_updated, :success, payment_entity)

          # Return as payment entity
          Result::Success.new(payment_entity)
        end
      end
    end

    def void_payment(community_id, transaction_id, payment, flow, m_acc, note = nil)
      with_success(community_id, transaction_id,
        MerchantData.create_do_void({
            receiver_username: m_acc[:payer_id],

            # Void order if it exists, it automatically voids any
            # authorization connected to the payment but with auth
            # flow we have no order so void the authorization
            # directly.
            transaction_id: payment[:order_id] ? payment[:order_id] : payment[:authorization_id],
            note: note
          }),
        error_policy: {
          codes_to_retry: ["10001", "x-timeout", "x-servererror"],
          try_max: 5
        }
        ) do |void_res|
        with_success(community_id, transaction_id, MerchantData.create_get_transaction_details({
              receiver_username: m_acc[:payer_id],
              transaction_id: payment[:order_id] ? payment[:order_id] : payment[:authorization_id],
            })) do |payment_res|
          payment = PaymentStore.update(
            data: payment_res,
            community_id: community_id,
            transaction_id: transaction_id)

          payment_entity = APIDataTypes.create_payment(payment)

          # Trigger payment_updated
          @events.send(:payment_updated, flow, payment_entity)

          Result::Success.new(payment_entity)
        end
      end
    end

    def proc_status_response(proc_token)
      Result::Success.new(
        APIDataTypes.create_process_status({
            process_token: proc_token[:process_token],
            completed: proc_token[:op_completed],
            result: proc_token[:op_output]}))
    end


    # Error handlers
    #

    def handle_failed_create_payment(token)
      -> (cid, txid, request, err_response) do
        data =
          if err_response[:error_code] == "10486"
            {redirect_url: token[:express_checkout_url]}
          elsif ["10485", "13116"].include?(err_response[:error_code])
            # 10485 = Payment not authorized, meaning user logged in
            # at PayPal but didn't press Pay yet.
            #
            # 13116 = Payment in progress, we already made an API call
            # to complete the authorization.
            #
            # Do not cancel token yet if the user is in the middle of
            # authenticating / paying. Retry tokens logic might try
            # completing the payment in this phase and we don't want
            # that to trigger token cancellation.
            nil
          else
            request_cancel(cid, token[:token])
            nil
          end

        log_and_return(cid, txid, request, err_response, data || {})
      end
    end

    def handle_failed_authorization(payment, m_acc)
      -> (cid, txid, request, err_response) do
        if err_response[:error_code] == "10486"
          # Special handling for 10486 error. Return error response and do NOT void.
          token = PaypalService::Store::Token.get_for_transaction(payment[:community_id], payment[:transaction_id])
          redirect_url = append_order_id(remove_token(token[:express_checkout_url]), payment[:order_id])
          log_and_return(cid, txid, request, err_response, {redirect_url: "#{redirect_url}"})
        else
          void_failed_payment(payment, m_acc).call(payment[:community_id], payment[:transaction_id], request, err_response)
        end
      end
    end

    def void_failed_payment(payment, m_acc)
      -> (cid, txid, request, err_response) do
        void_payment(cid, txid, payment, :error, m_acc)

        # Return original error
        log_and_return(cid, txid, request, err_response)
      end
    end

    def append_order_id(url_str, order_id)
      URLUtils.append_query_param(url_str, "order_id", order_id)
    end

    def remove_token(url_str)
      URLUtils.remove_query_param(url_str, "token")
    end

  end
end
