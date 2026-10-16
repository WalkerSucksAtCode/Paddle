import AppKit
import PaddleCore
import SwiftUI

/// Popover shown when clicking the address bar's security/lock icon:
/// connection security (TLS certificate details), per-site permission overrides
/// (content blocking, location, notifications, autoplay, JavaScript), and data clearing.
struct SiteSecurityView: View {
    let tab: Tab
    let model: BrowserModel
    let app: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var clearedDataNotice: String?

    private var url: URL? { tab.url }
    private var host: String {
        guard let url else { return "" }
        let h = url.host(percentEncoded: false) ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private var scheme: String { url?.scheme?.lowercased() ?? "" }
    private var isHTTPS: Bool { scheme == "https" }
    private var isHTTP: Bool { scheme == "http" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if isHTTPS || isHTTP {
                securitySection
                Divider()
                permissionsSection
                Divider()
                actionsSection
            } else {
                internalPageSection
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.system(size: 22))
                .foregroundStyle(headerIconColor)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(host.isEmpty ? (url?.absoluteString ?? "Page") : host)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var headerIcon: String {
        if isHTTPS {
            return tab.isSecure ? "lock.fill" : "lock.open.trianglebadge.exclamationmark"
        } else if isHTTP {
            return "exclamationmark.triangle.fill"
        }
        return "shield.fill"
    }

    private var headerIconColor: Color {
        if isHTTPS {
            return tab.isSecure ? .green : .orange
        } else if isHTTP {
            return .red
        }
        return .secondary
    }

    private var headerTitle: String {
        if isHTTPS {
            return tab.isSecure ? "Connection is secure" : "Connection is not fully secure"
        } else if isHTTP {
            return "Connection is not secure"
        }
        return "Internal Page"
    }

    // MARK: - Security / Certificate details

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isHTTPS {
                if let cert = tab.certificateInfo {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 11))
                        Text(cert.isValid ? "Certificate is valid" : "Certificate has warnings")
                            .font(.system(size: 11, weight: .medium))
                    }
                    if !cert.subject.isEmpty {
                        row("Issued to", cert.subject)
                    }
                    if !cert.issuer.isEmpty {
                        row("Issued by", cert.issuer)
                    }
                } else {
                    Text("Encrypted with TLS.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !tab.isSecure {
                    Text("Some content on this page was loaded over an unencrypted connection (mixed content).")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            } else if isHTTP {
                Text("Information (such as passwords, messages or credit cards) sent to this site can be seen or modified by others on your network.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 10))
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: - Site Permissions

    private var permissionsSection: some View {
        let policy = app.config.sitePolicy(forHost: host)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Permissions for this site")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            // Content Blocking
            Toggle(isOn: Binding(
                get: { policy.contentBlocking },
                set: { value in
                    Task { await app.writeSiteSetting(.contentBlocking, .bool(value), forKey: host) }
                }
            )) {
                Label("Content Blockers", systemImage: "shield")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Location
            HStack {
                Label("Location", systemImage: "location")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: Binding(
                    get: { policy.location },
                    set: { value in
                        Task { await app.writeSiteSetting(.location, .string(value.rawValue), forKey: host) }
                    }
                )) {
                    Text("Ask").tag(SiteSettings.Permission.ask)
                    Text("Allow").tag(SiteSettings.Permission.allow)
                    Text("Deny").tag(SiteSettings.Permission.deny)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 80)
            }

            // Notifications
            HStack {
                Label("Notifications", systemImage: "bell")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: Binding(
                    get: { policy.notifications },
                    set: { value in
                        Task { await app.writeSiteSetting(.notifications, .string(value.rawValue), forKey: host) }
                    }
                )) {
                    Text("Ask").tag(SiteSettings.Permission.ask)
                    Text("Allow").tag(SiteSettings.Permission.allow)
                    Text("Deny").tag(SiteSettings.Permission.deny)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 80)
            }

            // Autoplay
            HStack {
                Label("Autoplay", systemImage: "play.circle")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: Binding(
                    get: { policy.autoplay },
                    set: { value in
                        Task { await app.writeSiteSetting(.autoplay, .string(value.rawValue), forKey: host) }
                    }
                )) {
                    Text("Muted").tag(SiteSettings.Autoplay.muted)
                    Text("Allow").tag(SiteSettings.Autoplay.allow)
                    Text("Block").tag(SiteSettings.Autoplay.block)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 80)
            }

            // JavaScript
            Toggle(isOn: Binding(
                get: { policy.javaScript },
                set: { value in
                    Task { await app.writeSiteSetting(.javaScript, .bool(value), forKey: host) }
                }
            )) {
                Label("JavaScript", systemImage: "applescript")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 6) {
            if let notice = clearedDataNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Clear Site Data…") {
                    Task {
                        let count = await app.web.clearData(forHost: host, isPrivate: model.isPrivate, profile: model.profileID)
                        clearedDataNotice = count > 0 ? "Cleared cookies and cache for \(host)." : "No stored data found for \(host)."
                    }
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
                .foregroundStyle(.red)

                Spacer()

                Button("Site Settings…") {
                    dismiss()
                    model.showSettings(pane: .sites)
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var internalPageSection: some View {
        Text("This is an internal browser page or local file.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
