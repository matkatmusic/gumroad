Fixes #4060

## Problem

When a creator updates a membership tier price and enables "apply price changes to existing memberships," inactive (deactivated) subscribers are still charged the old rate upon resubscribing. This happens because `ScheduleMembershipPriceUpdatesJob` only creates `SubscriptionPlanChange` records for active subscriptions — deactivated ones are skipped entirely. When the subscriber later reactivates, `current_subscription_price_cents` returns the stale price from `original_purchase.displayed_price_cents`.

## Root Cause

`Subscription#current_subscription_price_cents` always returns the original purchase price. It has no awareness of tier-level price changes that occurred while the subscription was inactive. `ScheduleMembershipPriceUpdatesJob` creates `SubscriptionPlanChange` records only for active subscriptions (line 15 skips deactivated ones), so inactive subscribers never receive a plan change record, and the old price persists through reactivation.

## Approach

Rather than modifying `ScheduleMembershipPriceUpdatesJob` to also process inactive subscriptions (which would create plan change records that may never be applied, and wouldn't handle subscribers who deactivate *after* the job runs but *before* the effective date), the fix is at the point of price resolution: `current_subscription_price_cents`.

When the tier has `apply_price_changes_to_existing_memberships?` enabled and `subscription_price_change_effective_date` is today or earlier, the method recalculates the price from current tier pricing using the same `set_price_and_rate` + transaction rollback pattern already used by `ScheduleMembershipPriceUpdatesJob`. This temporarily computes what the purchase price would be at current tier rates without persisting the change, then reloads the purchase to clear in-memory state.

This approach is safe for active subscriptions too — those whose original purchase was already updated via `update_current_plan!` will get the same value back from recalculation. All downstream consumers (`RestartAtCheckoutService`, `UpdaterService`, `build_purchase`, `RecurringChargeWorker`, checkout presenter) already read from this single method, so the new price propagates automatically without any other file changes.

---

This PR was implemented with AI assistance using Claude Code for code generation. All code was self-reviewed.
