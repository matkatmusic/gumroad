# Interactive demo for issue #4060
# Run with: DISABLE_SPRING=1 bin/rails runner script/demo_price_change_scenario.rb
#
# Pauses at each step so you can take screenshots.
# Press Enter to advance to the next step.

def pause(message)
  puts "\n>>> #{message}"
  puts ">>> Press Enter to continue..."
  $stdin.gets
end

seller = User.find_by(email: "seller@gumroad.com")
abort "Seller not found. Run bin/rails db:seed first." unless seller

buyer_email = "buyer@example.com"
buyer = User.find_by(email: buyer_email)
unless buyer
  buyer = User.new(
    email: buyer_email,
    name: "Test Buyer",
    username: "testbuyer",
    confirmed_at: Time.current
  )
  buyer.password = "password"
  buyer.save!(validate: false)
end

product = seller.products.find_by(unique_permalink: "demomembership")
if product
  puts "Cleaning up previous demo data..."
  product.subscriptions.each do |sub|
    sub.purchases.destroy_all
    sub.subscription_plan_changes.destroy_all
    sub.destroy!
  end
  product.alive_variants.each { |v| v.prices.destroy_all }
  product.destroy!
end

# ============================================================
puts "\n" + "=" * 60
puts "STEP 1: Create membership product at $5/month"
puts "=" * 60

product = seller.products.new(
  name: "Demo Membership (Issue 4060)",
  unique_permalink: "demomembership",
  is_recurring_billing: true,
  is_tiered_membership: true,
  native_type: Link::NATIVE_TYPE_MEMBERSHIP,
  subscription_duration: :monthly,
  price_range: "5"
)
product.save!(validate: false)

tier_category = product.tier_category
tier = tier_category.variants.first
tier.update!(name: "Standard Tier")
tier.save_recurring_prices!({ monthly: { enabled: true, price: 5 } })
tier.reload
monthly_price = tier.prices.alive.is_buy.find_by(recurrence: "monthly")

puts "Product created: #{product.name}"
puts "Tier: #{tier.name} at $#{monthly_price.price_cents / 100.0}/month"

pause(<<~MSG.chomp)
  Screenshot: Product edit page showing $5/month tier
  Log in as: seller@gumroad.com / password / 2FA: 000000
  URL: https://gumroad.dev/products/#{product.unique_permalink}/edit
MSG

# ============================================================
puts "\n" + "=" * 60
puts "STEP 2: Customer subscribes at $5/month"
puts "=" * 60

merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)

subscription = Subscription.new(link: product, user: buyer)
subscription.payment_options.build(price: product.default_price)
subscription.save!

purchase = Purchase.new(
  link: product,
  seller: seller,
  purchaser: buyer,
  email: buyer_email,
  full_name: "Test Buyer",
  subscription: subscription,
  is_original_subscription_purchase: true,
  price_cents: 500,
  displayed_price_cents: 500,
  total_transaction_cents: 500,
  shipping_cents: 0,
  tax_cents: 0,
  gumroad_tax_cents: 0,
  fee_cents: 0,
  affiliate_credit_cents: 0,
  variant_attributes: [tier],
  purchase_state: "successful",
  succeeded_at: 2.months.ago,
  created_at: 2.months.ago,
  stripe_transaction_id: "demo_txn_#{SecureRandom.hex(8)}",
  stripe_fingerprint: "demo_fp_#{SecureRandom.hex(8)}",
  charge_processor_id: StripeChargeProcessor.charge_processor_id,
  merchant_account: merchant_account,
  ip_address: "127.0.0.1",
  browser_guid: SecureRandom.uuid,
  card_type: "visa",
  card_visual: "**** **** **** 4242",
  card_country: "US",
  flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 500)
)
purchase.save!(validate: false)

puts "Subscription created: #{subscription.external_id}"
puts "Original purchase: $#{purchase.displayed_price_cents / 100.0} (ID: #{purchase.id})"

pause(<<~MSG.chomp)
  Screenshot: Customers page showing active subscription at $5/month
  Log in as: seller@gumroad.com / password / 2FA: 000000
  URL: https://gumroad.dev/customers/#{product.unique_permalink}
MSG

# ============================================================
puts "\n" + "=" * 60
puts "STEP 3: Customer's subscription expires (deactivation)"
puts "=" * 60

subscription.update!(
  deactivated_at: 1.month.ago,
  cancelled_at: 1.month.ago,
  cancelled_by_buyer: true
)

puts "Subscription deactivated: #{subscription.deactivated?}"
puts "Subscription alive?: #{subscription.alive?}"

pause(<<~MSG.chomp)
  Screenshot: Customers page showing inactive/cancelled subscription
  Log in as: seller@gumroad.com / password / 2FA: 000000
  URL: https://gumroad.dev/customers/#{product.unique_permalink}
MSG

# ============================================================
puts "\n" + "=" * 60
puts "STEP 4: Seller changes tier price to $8/month with 'apply to existing'"
puts "=" * 60

monthly_price.update!(price_cents: 800)
effective_date = Date.today
tier.update_columns(
  subscription_price_change_effective_date: effective_date,
  flags: tier.flags | 2
)
tier.reload

puts "Tier price updated to: $#{monthly_price.reload.price_cents / 100.0}/month"
puts "apply_price_changes_to_existing_memberships: #{tier.apply_price_changes_to_existing_memberships?}"
puts "Effective date: #{tier.subscription_price_change_effective_date}"

pause(<<~MSG.chomp)
  Screenshot: Product edit page showing $8/month tier with 'apply to existing' enabled
  Log in as: seller@gumroad.com / password / 2FA: 000000
  URL: https://gumroad.dev/products/#{product.unique_permalink}/edit
MSG

# ============================================================
puts "\n" + "=" * 60
puts "STEP 5: Verify current_subscription_price_cents returns new price"
puts "=" * 60

subscription.reload
new_price = subscription.current_subscription_price_cents
puts "current_subscription_price_cents: $#{new_price / 100.0}/month"

if new_price == 800
  puts "FIX CONFIRMED: Inactive subscriber sees updated $8/month rate"
else
  puts "BUG: Price is still $#{new_price / 100.0}/month (expected $8.00)"
end

pause(<<~MSG.chomp)
  Screenshot: Checkout page showing $8/month for reactivation
  Log in as: buyer@example.com / password (use incognito/separate browser)
  URL: https://gumroad.dev/l/#{product.unique_permalink}
MSG

# ============================================================
puts "\n" + "=" * 60
puts "STEP 6: Customer renews subscription at $8/month"
puts "=" * 60

subscription.update!(
  deactivated_at: nil,
  cancelled_at: nil,
  cancelled_by_buyer: false
)

renewal_purchase = Purchase.new(
  link: product,
  seller: seller,
  purchaser: buyer,
  email: buyer_email,
  full_name: "Test Buyer",
  subscription: subscription,
  is_original_subscription_purchase: false,
  price_cents: 800,
  displayed_price_cents: 800,
  total_transaction_cents: 800,
  shipping_cents: 0,
  tax_cents: 0,
  gumroad_tax_cents: 0,
  fee_cents: 0,
  affiliate_credit_cents: 0,
  variant_attributes: [tier],
  purchase_state: "successful",
  succeeded_at: Time.current,
  created_at: Time.current,
  stripe_transaction_id: "demo_renewal_#{SecureRandom.hex(8)}",
  stripe_fingerprint: "demo_fp_#{SecureRandom.hex(8)}",
  charge_processor_id: StripeChargeProcessor.charge_processor_id,
  merchant_account: merchant_account,
  ip_address: "127.0.0.1",
  browser_guid: SecureRandom.uuid,
  card_type: "visa",
  card_visual: "**** **** **** 4242",
  card_country: "US",
  flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 800)
)
renewal_purchase.save!(validate: false)

puts "Subscription reactivated: alive? = #{subscription.alive?}"
puts "Renewal purchase created: $#{renewal_purchase.displayed_price_cents / 100.0} (ID: #{renewal_purchase.id})"

pause(<<~MSG.chomp)
  Screenshot: Customers page showing reactivated subscription with $8 renewal charge
  Log in as: seller@gumroad.com / password / 2FA: 000000
  URL: https://gumroad.dev/customers/#{product.unique_permalink}
MSG

# ============================================================
puts "\n" + "=" * 60
puts "STEP 7: Verify both purchases visible in seller portal"
puts "=" * 60

puts "Original purchase: $#{purchase.displayed_price_cents / 100.0} on #{purchase.created_at.strftime('%Y-%m-%d')}"
puts "Renewal purchase:  $#{renewal_purchase.displayed_price_cents / 100.0} on #{renewal_purchase.created_at.strftime('%Y-%m-%d')}"
puts "\nScreenshot: Sales page showing both the $5 original and $8 renewal"
puts "Log in as: seller@gumroad.com / password / 2FA: 000000"
puts "URL: https://gumroad.dev/customers/sales"

puts "\n" + "=" * 60
puts "DONE — All screenshots captured."
puts "=" * 60
