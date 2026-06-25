-- Add stripe_subscription_id to profiles for subscription lifecycle tracking.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS stripe_subscription_id text;
