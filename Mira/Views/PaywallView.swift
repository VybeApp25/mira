import SwiftUI
import AppKit

// The canonical in-app upgrade surface. Presented as a sheet from anywhere a
// gated feature is hit (Agents, Settings, …). Mirrors the onboarding paywall but
// is reusable post-onboarding and adds "Manage subscription" for paid users.
// Checkout / portal both open in the browser via StripePurchaseService; the plan
// reflects in-app on return (EntitlementService polls + refreshes on activation).
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var entitlements = EntitlementService.shared

    @State private var working:  SubscriptionPlan? = nil   // upgrade in flight
    @State private var managing: Bool = false              // portal in flight
    @State private var errorMsg: String? = nil

    private let accent      = DS.Colors.accent
    private let ultraAccent = Color(red: 0.75, green: 0.45, blue: 0.95)

    private var currentPlan: SubscriptionPlan { entitlements.plan }
    private var isPaid: Bool { currentPlan != .free }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if let err = errorMsg {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                    }

                    planCard(
                        plan: .free, name: "Free", price: "$0",
                        features: ["5 agent tasks / month", "10 min voice / day", "Screen guidance"],
                        planAccent: Color.white.opacity(0.30)
                    )
                    planCard(
                        plan: .pro, name: "Pro", price: "$19.99/mo",
                        features: ["100 agent tasks / month", "10 hrs voice / day", "Background agents", "Priority speed"],
                        planAccent: accent
                    )
                    planCard(
                        plan: .ultra, name: "Ultra", price: "$49.99/mo",
                        features: ["500 agent tasks / month", "Unlimited voice", "Multi-agent workflows", "Ultra speed"],
                        planAccent: ultraAccent
                    )

                    if isPaid {
                        Button {
                            manageSubscription()
                        } label: {
                            HStack(spacing: 6) {
                                if managing { ProgressView().controlSize(.small) }
                                Text(managing ? "Opening…" : "Manage subscription")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .disabled(managing)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 380, height: 520)
        .background(DS.Colors.background)
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.25), ultraAccent.opacity(0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Text(isPaid ? "Your Mira plan" : "Unlock the full Mira.")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(isPaid
                     ? "You're on \(currentPlan.displayName). Change or manage it anytime."
                     : "Run agents in the background, all day — and more voice.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .frame(height: 110)
    }

    // MARK: - Plan card

    @ViewBuilder
    private func planCard(plan: SubscriptionPlan, name: String, price: String,
                          features: [String], planAccent: Color) -> some View {
        let isCurrent = plan == currentPlan
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text(price)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
            }
            ForEach(features, id: \.self) { f in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(planAccent)
                    Text(f)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            ctaButton(plan: plan, name: name, planAccent: planAccent, isCurrent: isCurrent)
                .padding(.top, 4)
        }
        .padding(14)
        .background(DS.Colors.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? planAccent.opacity(0.6) : Color.white.opacity(0.06),
                        lineWidth: isCurrent ? 1.5 : 1)
        )
        .cornerRadius(12)
    }

    @ViewBuilder
    private func ctaButton(plan: SubscriptionPlan, name: String,
                           planAccent: Color, isCurrent: Bool) -> some View {
        if isCurrent {
            Text("Current plan")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .clipShape(Capsule())
        } else if plan == .free {
            // Downgrade to Free is done via the billing portal (cancel), not here.
            EmptyView()
        } else {
            Button { upgrade(to: plan) } label: {
                HStack(spacing: 6) {
                    if working == plan { ProgressView().controlSize(.small) }
                    Text(working == plan ? "Opening…"
                         : (isPaid ? "Switch to \(name)" : "Upgrade to \(name)"))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(planAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(working != nil)
        }
    }

    // MARK: - Actions

    private func upgrade(to plan: SubscriptionPlan) {
        guard working == nil else { return }
        errorMsg = nil
        working = plan
        Task {
            do {
                try await StripePurchaseService.shared.startCheckout(plan: plan)
                // Browser opened — close the sheet; the plan updates on return.
                dismiss()
            } catch {
                errorMsg = error.localizedDescription
            }
            working = nil
        }
    }

    private func manageSubscription() {
        guard !managing else { return }
        errorMsg = nil
        managing = true
        Task {
            do {
                try await StripePurchaseService.shared.openBillingPortal()
                dismiss()
            } catch {
                errorMsg = error.localizedDescription
            }
            managing = false
        }
    }
}
