# Sydex security and data-loss audit — 2026-11-09

This is a source audit of the current Flutter project and checked-in Supabase migrations. No production database or customer data was changed.

## Priorities

### Critical before production

- Client-side zero-knowledge encryption is not implemented. Supabase RLS limits workspace access, but database administrators and service-role code can still see plaintext records. Do not describe the current system as zero-knowledge.
- The Google Play verification Edge Function, Real-time Developer Notifications handler, and reconciliation worker are not deployed/configured. Subscription enforcement must remain disabled until those are tested.
- Existing financial RPCs use database transactions for individual operations, but the full offline durable queue and conflict-resolution workflow requested in the audit does not yet exist.

### High priority

- Verify every exposed table, storage bucket, view, and RPC against the active Supabase project. Checked-in migrations contain many protections, but a repository audit cannot prove the remote schema matches them.
- Replace any remaining direct client writes to sensitive settings with owner-checked RPCs and confirm all `SECURITY DEFINER` functions have fixed search paths and restricted execution grants.
- Configure encrypted backups, point-in-time recovery, retention, and restoration drills in Supabase. These cannot be claimed from source code alone.
- Add device enrollment and key wrapping only after an approved encryption design; do not migrate plaintext columns in place.

### Medium priority

- Move user-facing date display to the device-local timezone while keeping server timestamps authoritative. New transaction forms already carry a separate transaction date; the date selector changes only that business date.
- Add synthetic integration tests for cross-company reads/writes, authorization, idempotency, duplicate retries, and concurrent balance updates against a disposable Supabase project.

## Confirmed protections in source

- Workspace queries commonly use `current_company_id()` and company-scoped policies.
- Payment idempotency and append-only financial audit logging are present in migration `20261106114341_add_payment_idempotency_and_audit_log.sql`.
- Privileged RPC grants and search paths are hardened in `20261102100000_harden_security_definer_functions.sql`.
- The subscription entitlement read path is workspace-scoped and does not allow Flutter to write verified status.

## Date changes in this pass

- `BusinessDateService.load()` now starts each process with the current local date and clears a prior process's stored date.
- Manual dates are marked explicitly and remain selected for the current session.
- `Today` clears manual selection and restores the current local date.
- Windows login includes the compact business-date selector; Android uses the same service for new-entry defaults.
- Existing transaction creation timestamps are untouched.

## Deliberately not implemented yet

- Client-side encryption migration.
- Two-party recovery key ceremony.
- Production paywall or subscription-based transaction blocking.
- Production backup claims or destructive schema changes.

These require design review, credentials/configuration, test data, and explicit approval before deployment.
