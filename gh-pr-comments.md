# Self-Review Comments

Post these as review comments on the PR diff.

---

## `app/models/subscription.rb` — `current_subscription_price_cents` (line 202-207)

The `elsif` branch is ordered before the `else` deliberately. For installment plans, the early return is unchanged. For the new branch, `membership_price_change_effective?` is a lightweight check (two boolean/date comparisons on the tier) before the heavier `calculate_updated_tier_price` is called. The fallback to `base_subscription_price_cents` when `updated_price` is nil or zero prevents charging $0 if the tier pricing is misconfigured.

---

## `app/models/subscription.rb` — `base_subscription_price_cents` (line 905-909)

Extracted from the original `current_subscription_price_cents` body — this is a pure refactor with identical behavior. Now reused by both the `else` branch and as the fallback in the `elsif` branch.

---

## `app/models/subscription.rb` — `membership_price_change_effective?` (line 911-916)

No plan-change-existence check here intentionally. Checking for a `SubscriptionPlanChange` record would miss the case where a creator does multiple sequential price changes — a subscriber active for change #1 would have a plan change record, but if inactive for change #2, the record from #1 would mask the missing #2. Checking tier settings directly always reflects the latest state.

---

## `app/models/subscription.rb` — `calculate_updated_tier_price` (line 918-929)

Same pattern as `ScheduleMembershipPriceUpdatesJob` lines 50-54. The `reload` after the rolled-back transaction is necessary because `set_price_and_rate` mutates the purchase object's in-memory attributes (e.g. `displayed_price_cents`), and the rollback only reverts the database — the Ruby object retains the mutated values.

---

## `spec/models/subscription_spec.rb` — `travel_to` usage throughout

The `8.days.from_now` + `travel_to(9.days.from_now)` pattern is required because the `apply_price_changes_to_existing_memberships` validation on `BaseVariant` rejects effective dates less than 7 days out. We set a valid future date, then time-travel past it to test the "effective date in the past" behavior.

---

## `spec/services/subscription/restart_at_checkout_service_spec.rb` — subscription setup (line 248-260)

Uses a manual subscription + purchase setup instead of `create_subscription_for_product` because that helper uses `product.price_cents` (the product base price, not the tier price) and `product.tiers.to_a` (all tiers). This test needs a subscription at a specific tier's price ($5) to verify the price changes to $6 after the tier update.
