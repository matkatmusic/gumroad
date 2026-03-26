# Fix: Inactive subscribers reactivating don't receive new membership rates

**Issue:** [antiwork/gumroad#4060](https://github.com/antiwork/gumroad/issues/4060)

## Context

When a creator updates a membership tier's price (via "apply price changes to existing memberships"), `ScheduleMembershipPriceUpdatesJob` creates `SubscriptionPlanChange` records for **active** subscriptions only — deactivated ones are skipped (line 15). When an inactive subscriber later reactivates, `current_subscription_price_cents` returns the old price from `original_purchase.displayed_price_cents`. This old price propagates through checkout presenter, `RestartAtCheckoutService`, `UpdaterService`, `build_purchase`, and the charge flow.

## Root Cause

`Subscription#current_subscription_price_cents` (line 199-207) always returns the original purchase price. It has no awareness of tier-level price changes that occurred while the subscription was inactive.

## Approach

Modify `current_subscription_price_cents` to detect when a membership price change is effective and recalculate from current tier pricing.

**Guard condition** (`membership_price_change_effective?`):
1. Tier has `apply_price_changes_to_existing_memberships?` enabled
2. `subscription_price_change_effective_date <= Date.today`

No plan-change-existence check needed — avoids a bug with multiple sequential price changes where a subscriber was active for change #1 but inactive for change #2.

**Why this is safe for active subscriptions too:**
- Active subs whose original purchase was already updated via `update_current_plan!` → `base_subscription_price_cents` already returns new price → recalculation returns same value → no change in behavior
- Active subs with pending plan changes → recalculation returns current tier price → `RecurringChargeWorker` also applies the plan change → result is consistent
- `FindSubscriptionsWithMissingChargeWorker` only processes active subs (`where(deactivated_at: nil)`) on `queue: :low` — extra computation is acceptable

**Why there's no timing issue with `resubscribe!`:**
- `UpdaterService` calls `resubscribe!` at line 136 (makes sub alive), then charges at line 155
- The guard uses tier settings, NOT `!alive?` — so it returns the new price both before and after `resubscribe!`
- `new_price_cents` (line 192-193) → `current_subscription_price_cents` → new price at all times

**No circular dependency:** `set_price_and_rate` → `minimum_paid_price_cents` → checks `is_recurring_subscription_charge` which is `false` for the original subscription purchase → calculates from product/tier pricing via `base_product_price_cents` + `variant_extra_cost`, not `current_subscription_price_cents`.

## Files to Modify

### 1. `app/models/subscription.rb`

**Modify `current_subscription_price_cents`** (line 199-207):

```ruby
def current_subscription_price_cents
  if is_installment_plan
    original_purchase.minimum_paid_price_cents
  elsif membership_price_change_effective?
    updated_price = calculate_updated_tier_price
    updated_price.present? && updated_price > 0 ? updated_price : base_subscription_price_cents
  else
    base_subscription_price_cents
  end
end
```

**Add private helpers:**

```ruby
def base_subscription_price_cents
  discount_applies_to_next_charge? ?
    original_purchase.displayed_price_cents :
    original_purchase.displayed_price_cents_before_offer_code(include_deleted: true)
end

def membership_price_change_effective?
  t = tier
  t&.apply_price_changes_to_existing_memberships? &&
    t.subscription_price_change_effective_date.present? &&
    t.subscription_price_change_effective_date <= Date.today
end

def calculate_updated_tier_price
  new_price = nil
  ActiveRecord::Base.transaction do
    original_purchase.set_price_and_rate
    new_price = discount_applies_to_next_charge? ?
      original_purchase.displayed_price_cents :
      original_purchase.displayed_price_cents_before_offer_code(include_deleted: true)
    raise ActiveRecord::Rollback
  end
  original_purchase.reload # Reset in-memory state after rollback
  new_price
end
```

**Why `set_price_and_rate` + rollback:** Same pattern as `ScheduleMembershipPriceUpdatesJob` (lines 49-54). Recalculates from current tier prices without persisting. `original_purchase.reload` prevents in-memory state leak from the rollback (DB is clean but Ruby object attributes are mutated by `set_price_and_rate`).

### 2. `spec/models/subscription_spec.rb`

Add tests under `describe "#current_subscription_price_cents"`:

- Inactive sub + tier price change enabled + effective date passed → returns new price
- Inactive sub + effective date in future → returns old price
- Inactive sub + feature not enabled → returns old price
- Active sub (already has plan change applied) → returns new price consistently
- Inactive sub with offer code + discount still applies → returns updated discounted price
- Inactive sub + price unchanged → returns same price

**Scenario test (from issue):**
A user subscribes to a membership at $50/month. The membership auto-expires after 3 months. In month 4, the creator changes the rate to $60/month (enables `apply_price_changes_to_existing_memberships`, sets effective date). In month 5, the user resubscribes. They should be charged $60/month going forward.

### 3. `spec/services/subscription/restart_at_checkout_service_spec.rb`

Integration test: reactivating a subscription whose tier had a price change → new price flows through to `UpdaterService` params correctly.

## How It Propagates (no other file changes needed)

| Code Path | How it gets the new price |
|---|---|
| **Checkout presenter** (line 210) | `current_subscription_price_cents` → new price shown to user |
| **RestartAtCheckoutService** (line 33) | Falls back to `current_subscription_price_cents` → new price |
| **UpdaterService validation** (line 186) | `new_price_cents` → `current_subscription_price_cents` → new price |
| **UpdaterService charge** (line 357) | `amount_owed` → `new_price_cents` → new price |
| **build_purchase** (line 226) | Falls back to `current_subscription_price_cents` → new price |
| **Future RecurringChargeWorker** | `current_subscription_price_cents` → recalculates → new price |

## Edge Cases

- **Offer codes**: `discount_applies_to_next_charge?` preserved in both base and recalculated paths
- **PWYW**: `set_price_and_rate` → `determine_customized_price_cents` respects custom pricing
- **Installment plans**: Early return at top of method (unchanged)
- **Pre-feature subscribers**: Guard only requires tier settings — works regardless of subscription age
- **Multiple price changes**: `set_price_and_rate` always computes latest tier price
- **Creator disables feature**: `apply_price_changes_to_existing_memberships?` → false → guard fails → old behavior
- **Stale checkout page**: Frontend sends old `perceived_price_cents` → `validate_perceived_prices_match` fails → "price just changed" error → user refreshes

## Verification

1. Existing tests (no regressions):
   ```
   bundle exec rspec spec/models/subscription_spec.rb -e "current_subscription_price_cents"
   bundle exec rspec spec/sidekiq/schedule_membership_price_updates_job_spec.rb
   bundle exec rspec spec/services/subscription/restart_at_checkout_service_spec.rb
   ```

2. New tests confirming the fix works end-to-end (scenario test + unit tests)
