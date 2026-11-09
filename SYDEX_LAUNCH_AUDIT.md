# Sydex launch audit — Stage 0

Audit date: 2026-11-09

This is an inspection-only report. No production database, customer record, transaction, key, or migration was changed during Stage 0.

## Existing architecture and features

- Flutter app with Material 3 themes and shared services under `lib/services`.
- Supabase Auth and PostgREST client initialized in `lib/main.dart` with a compile-time publishable key.
- Owner and Salesman dashboards, customers, purchases, payments, cheque handling, ledger balances, reports, routes, signatures, receipts, exports, tutorials, and settings are present.
- Supabase migrations use `companies`, `company_members`, `profiles`, company-scoped records, RLS policies, and role-aware RPCs.
- Windows and Android platform folders are present.
- Google Play subscription client scaffolding exists in `subscription_service.dart`; the verified backend function is not present in the repository.
- GitHub Actions builds Android APK and Windows artifacts; Windows build depends on the `printing` plugin downloading PDFium.

## Confirmed existing protections

- `current_company_id()` and company-scoped policies are used broadly in migrations.
- Payment idempotency and financial audit triggers exist in `20261106114341_add_payment_idempotency_and_audit_log.sql`.
- Privileged function permissions and search paths are hardened in `20261102100000_harden_security_definer_functions.sql`.
- Customer deletion is an explicit owner RPC and records a financial audit event.
- The Flutter client uses a publishable Supabase key; no service-role key was found in Flutter source.
- Business-date handling now separates manual selection from automatic device-local date defaults.

## Missing or blocked launch requirements

### Critical

- Google Play purchase verification, acknowledgement, RTDN handling, and periodic reconciliation are not implemented/deployed.
- Subscription enforcement is intentionally disabled; production paywalls must remain disabled.
- Client-side encryption and two-party recovery are not implemented. Current Supabase storage is not zero-knowledge because backend/database administrators can access plaintext.
- A durable encrypted offline write queue with Pending Sync/Synced/Failed states is not implemented.
- Remote Supabase schema and storage configuration have not been verified in this environment.

### High

- Cross-workspace authorization tests are missing from the automated suite.
- Backup schedule, PITR, offsite encryption, retention, and restoration tests are not verifiable from repository source.
- Storage bucket policies need a live-project audit, especially `payment-signatures` and any receipt-related paths.
- The Windows `printing` plugin cannot download PDFium on the current network; local Windows builds are blocked by an HTTP gateway timeout. GitHub Actions has retry logic but has not been observed completing here.

### Medium

- Automated coverage is currently minimal: the repository has a basic widget test and focused business-date tests, but not financial, authorization, synchronization, billing, or platform regression suites.
- Dependency updates are available but have not been applied because compatibility and regression impact are not yet reviewed.

## Data-loss and financial risks

- Some client flows still perform reads and UI state changes around server RPCs; durable offline queuing is not universal.
- Existing financial RPCs provide atomic operations for important paths, but this audit has not proven every mutation is atomic or idempotent.
- A complete concurrent-edit/conflict strategy is missing.
- Existing destructive customer deletion behavior requires a product decision about archival versus permanent deletion; no destructive change was made during this stage.

## Security risks

- RLS correctness cannot be proven against the remote project without a live schema/policy audit and synthetic cross-business tests.
- RLS protects row access but does not provide zero-knowledge confidentiality from Supabase administrators.
- Subscription purchase verification currently calls a function name that is not present in `supabase/functions`.
- Secrets must remain in GitHub/Supabase secret stores; the publishable key is required at build time and must not be replaced by a service-role key.

## Tests and checks

Requested commands:

```text
flutter pub get
flutter analyze
flutter test
```

`flutter pub get` was started during this audit but stalled without producing a completion result in the local environment. `flutter analyze` and `flutter test` therefore were not claimed as passed. Windows release builds are separately blocked locally by the PDFium download failure described above.

## Recommended implementation order

1. Review and approve this Stage 0 audit.
2. Run live Supabase RLS/storage/RPC authorization tests against a disposable project.
3. Complete and test financial idempotency/offline synchronization gaps.
4. Configure and test Google Play verification, RTDN, acknowledgement, renewal, cancellation, refund, grace, hold, and expiry handling.
5. Verify backups and perform a safe restoration drill.
6. Design customer-controlled encryption and two-party recovery; stop for explicit approval before any encryption migration.
7. Expand Android/Windows regression coverage and resolve the PDFium build environment issue.
8. Perform the final release review only after all critical items have evidence.

## Stage 0 decision

Stage 0 inspection is complete. No application or database behavior was changed as part of this audit. Approval is required before starting Stage 1 database security work.
