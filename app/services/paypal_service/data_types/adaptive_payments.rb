module PaypalService
  module DataTypes

    module AdaptivePayments

      SetPay = EntityUtils.define_builder(
        [:method, const_value: :set_pay],
        [:item_name, :mandatory, :string],
        [:item_quantity, :fixnum, default: 1],

        [:require_shipping_address, :to_bool],
        [:item_price, :mandatory, :money],

        # If specified, require_shipping_address must be true
        [:shipping_total, :optional],

        # Must match item_price * item_quantity + shipping_total
        [:order_total, :mandatory, :money],

        [:receiver_username, :mandatory, :string],
        [:success, :mandatory, :string],
        [:cancel, :mandatory, :string],
        [:invnum, :mandatory, :string],
        [:merchant_brand_logo_url, :optional, :string])

      SetPayResponse = EntityUtils.define_builder(
        [:success, const_value: true],
        [:token, :mandatory, :string],
        [:redirect_url, :mandatory, :string],
        [:username_to, :mandatory, :string])

      module_function

      def create_set_pay(opts); SetPay.call(opts) end
      def create_set_pay_response(opts); SetPayResponse.call(opts) end

    end

  end
end
