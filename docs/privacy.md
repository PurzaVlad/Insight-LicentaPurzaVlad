# Privacy Policy

**Effective date:** May 25, 2026  
**Last updated:** May 25, 2026

This Privacy Policy explains how Insight ("the app", "we", "us") handles your information when you use the Insight application on iOS.

---

## 1. Summary

Insight is built around a simple principle: **your documents stay on your device**. The AI that reads and summarizes your documents runs entirely locally — no document content is ever uploaded to our servers for AI processing.

---

## 2. Information We Collect

### 2.1 Account Information
If you create an account, we collect:
- Email address
- Name (if signing in with Google or Apple)
- Authentication tokens (stored securely on your device via Keychain)

Account data is managed through Firebase Authentication (Google LLC). Firebase's privacy policy is available at https://firebase.google.com/support/privacy.

### 2.2 Documents
All documents you import, scan, or create within Insight are:
- Stored **only on your device**, in an encrypted local vault
- Never transmitted to our servers for AI processing
- Protected by iOS Data Protection (encrypted at rest)
- Protected by your passcode and Face ID

We do **not** have access to your documents.

### 2.3 File Conversion
Insight includes an optional file conversion feature (e.g. converting DOCX to PDF). When you use this feature:
- The file is transmitted over an encrypted HTTPS connection to a conversion server (hosted on Google Cloud Run)
- The conversion server processes the file and returns the result immediately
- **The server does not retain or store your file after conversion.** The file is deleted from server memory upon response.
- Conversion is a user-initiated action; no files are sent without your explicit request

### 2.4 On-Device AI Model
The AI model (approximately 1,2 GB) is downloaded from a public model repository (Hugging Face) upon your explicit consent during first-time setup. The model file is stored locally and never re-uploaded.

### 2.5 Usage Data
We do not currently collect analytics or usage telemetry.

---

## 3. Information We Do Not Collect

- We do **not** collect your document contents
- We do **not** use your data for advertising
- We do **not** sell your data to third parties
- We do **not** track you across other apps or websites
- We do **not** use cookies or tracking pixels

---

## 4. Data Storage and Security

- Documents are stored in your device's local file system, protected by iOS Data Protection APIs
- Authentication credentials are stored in the iOS Keychain
- Your passcode is stored in the iOS Keychain and never transmitted
- All network communication uses HTTPS/TLS encryption

---

## 5. Third-Party Services

| Service | Purpose | Privacy Policy |
|---------|---------|----------------|
| Firebase Authentication (Google) | Account sign-in | https://firebase.google.com/support/privacy |
| Google Sign-In | OAuth authentication | https://policies.google.com/privacy |
| Apple Sign-In | OAuth authentication | https://www.apple.com/legal/privacy/ |
| Google Cloud Run | File conversion server | https://cloud.google.com/terms/cloud-privacy-notice |
| Hugging Face | AI model download source | https://huggingface.co/privacy |

---

## 6. Children's Privacy

Insight is not directed to children under 13 years of age. We do not knowingly collect personal information from children under 13.

---

## 7. Your Rights

You can:
- **Delete your account** at any time from Settings → Account → Delete Account Permanently. This removes your authentication credentials from Firebase.
- **Delete your documents** at any time from within the app. Documents are only stored on your device.
- **Withdraw AI model consent** at any time from Settings → Privacy → Withdraw AI Model Consent. This will reset the AI model download and sign you out.
- **Contact us** with any privacy questions at contact.insightapp@gmail.com.

---

## 8. Data Retention

- Account data: retained until you delete your account
- Documents: stored locally on your device; deleted when you remove them or uninstall the app
- Conversion server: files are not retained after conversion (immediate deletion)

---

## 9. Changes to This Policy

We may update this Privacy Policy from time to time. The updated version will be indicated by the "Last updated" date at the top of this page. Continued use of the app after changes constitutes acceptance of the updated policy.

---

## 10. Contact

If you have questions about this Privacy Policy, please contact us at:

**Email:** contact.insightapp@gmail.com
