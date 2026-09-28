# App privacy disclosure review — 28 September 2026

This is a source-grounded release worksheet, not a submitted App Store Connect
answer. The app is currently a private build. Recheck the shipped binary, service
deployment, vendors and App Store Connect answers before distribution. The
`PrivacyInfo.xcprivacy` required-reason manifest is a different declaration;
its presence does not answer Apple's data-collection questions.

Apple defines collection as transmitting data off-device so the developer or a
partner can access it longer than needed to service the request in real time.
On-device-only processing does not count. Apple asks for all applicable data
types and purposes across the app and third-party partners, even when collection
only serves app functionality. See [App Privacy Details][apple-details] and
[Manage app privacy][apple-connect].

| Flow | Source evidence | Disclosure consequence to review |
| --- | --- | --- |
| Local ledger, plans, corrections, archives and encrypted backup | `docs/data-and-sync.md`; `FinanceApp/Persistence/DocumentExporter.swift` | These remain on device or in a file explicitly exported by the person. They do not alone establish developer collection. Confirm the shipping build has no upload, analytics or automatic backup path before using that conclusion. |
| Optional bank sync | `FinanceApp/Persistence/BankSync/BankSyncClient.swift`; service `service/src/api/mobile.ts`, `service/migrations/0001_init.sql` | The app sends a paired-device identifier and signed requests to a Worker. The service separately retrieves and retains normalized account details, balances and movements from banks through Enable Banking in Cloudflare D1. Treat **Other Financial Info** and possibly **Payment Info** as disclosure candidates; do not answer “no data collected” just because the local ledger is private. Apple distinguishes information entered only with a payment service outside the app from information accessible to the developer. |
| Pairing and request security | Service `service/migrations/0003_device_pairing.sql`, `service/src/api/device.ts`, `service/src/api/mobile.ts` | D1 keeps an opaque device ID, public key, optional operator label and last-seen time. **Device ID** is a strong candidate. The service receives an edge-supplied source IP for short-lived pairing limits and user-present provider context; check Cloudflare/Enable Banking retention and Apple's IP guidance before deciding whether another identifier, location or diagnostic type applies. |
| Service processing | Service `service/src/pages.ts`, `service/docs/security.md` | The current source names Enable Banking and Cloudflare and says old observations are not erased merely because consent ends. Confirm this exact notice is deployed and the processor terms still match the release. No advertising or sale is stated in source; verify actual vendors and service configuration before answering Apple's tracking question. |

The likely purpose for retained sync and device data is **App Functionality**.
Because the service can associate its device row and bank observations with one
paired user, review them as **Data Linked to You**; keyed provider IDs are not by
themselves proof of anonymization. Do not invoke Apple's optional regulated
financial-services exception without showing every required condition. The
bank service is a private POC, not an established public regulated-app exception.

Before a public release:

1. Inspect the final binary and production Worker/Cloudflare configuration for
   analytics, crash reporting, request logs, IP retention and new SDKs. Decide
   each Apple data type, purpose, linked status and tracking answer from the
   actual release, recording evidence beside the answer.
2. Publish an **app-wide** privacy policy at a stable public URL. The Worker's
   `/privacy` page currently describes the bank-sync service, not the local app,
   user-created ledger, backup/export choices and optional nature of pairing.
   Include contact, data retention/deletion and vendor processing accurately.
3. Enter and review the responses in App Store Connect, including optional
   bank-sync collection even if other people never pair. Preview the resulting
   label and publish it only when the app and policy are ready. Apple requires a
   public privacy-policy URL for an iOS App Store listing.

No App Store Connect response or public policy URL was published by this review.

[apple-details]: https://developer.apple.com/app-store/app-privacy-details/
[apple-connect]: https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
