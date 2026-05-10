# Privacy Policy

**Version:** 1.0  
**Effective Date:** May 10, 2026

## 1. Overview

MyEmail is a local macOS email client developed by Anton Korenskoy ("Developer", "we", "us"). This Privacy Policy explains what data the App handles, where it is stored, and how it is protected.

**The short version:** all your data stays on your device. We collect nothing and have no servers.

## 2. Data We Do Not Collect

The Developer does not collect, transmit, or have access to:
- Your email content (messages, attachments, metadata);
- Your email account credentials or OAuth2 tokens;
- Usage analytics, crash reports, or telemetry of any kind;
- Device identifiers or personal information.

## 3. Data Stored Locally on Your Device

The App stores the following data exclusively on your Mac:

| Data | Location |
|------|----------|
| Email messages and metadata | `~/Library/Application Support/MyEmail/` (SQLite via GRDB) |
| Attachments | `~/Library/Application Support/MyEmail/attachments/` |
| OAuth2 tokens and credentials | macOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`) |
| App preferences and settings | `~/Library/Preferences/` |

This data never leaves your device except via normal IMAP/SMTP communication directly between the App and your mail server.

## 4. Communication with Mail Servers

The App communicates directly with the mail servers you configure (e.g., Gmail via IMAP/SMTP). This communication is:
- Encrypted using TLS;
- Governed by your mail provider's own privacy policy (e.g., [Google Privacy Policy](https://policies.google.com/privacy)).

The Developer is not a party to this communication and cannot access it.

## 5. OAuth2 Authentication (Gmail and Compatible Providers)

When you authenticate via OAuth2, the App uses the PKCE flow (RFC 8252) with a loopback redirect URI. The authorization exchange happens entirely between your browser and the OAuth provider. The Developer does not receive or store OAuth tokens outside of your local Keychain.

## 6. Remote Content in Emails

HTML emails may reference remote images and resources. The App does not load remote content by default; a banner is shown asking for your permission. JavaScript is disabled entirely in the email renderer.

## 7. Third-Party Services

The App does not integrate any third-party analytics, advertising, or tracking SDKs.

## 8. Data Security

- Credentials are stored in the macOS Keychain with `kSecAttrAccessibleAfterFirstUnlock` accessibility.
- The local SQLite database is not additionally encrypted at rest beyond macOS full-disk encryption (FileVault). Enabling FileVault is recommended for sensitive data.
- The Developer assumes no liability for data loss due to hardware failure, OS issues, or unauthorized physical access to your device.

## 9. Children's Privacy

The App is not directed to children under 13 and does not knowingly collect any information from minors.

## 10. Changes to This Policy

The Developer may update this Privacy Policy at any time. The updated policy will be distributed with the App. Continued use after an update constitutes acceptance of the revised policy.

## 11. Contact

For privacy-related questions or requests: korenskoy@gmail.com
