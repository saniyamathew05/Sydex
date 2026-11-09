# Horizon --- Complete App Requirements & Project Specification

**Document purpose:** This is the consolidated product and
implementation brief for the Horizon app (`horizon`),
based on requirements and decisions discussed so far. Use it as the
source of truth when changing the app, reviewing code, planning
features, or handing work to another developer.

**Status:** Living requirements document. It records requested behavior
and known implementation concerns; it does **not** certify that every
item is already implemented or tested.

------------------------------------------------------------------------

## 1. Product overview

Horizon is a digital customer-ledger and sales/payment management
application for a business with more than 1,000 customers. It replaces
paper customer cards/ledgers used by a salesperson during customer
visits. A salesperson needs to identify a customer, see the outstanding
amount, record a sale or payment, capture a signature when required, and
have balances and history calculated and stored consistently.

The app must work on: - Android phones - iPhones - Desktop computers,
including macOS and Windows

The experience should be responsive and practical on both small and
large screens. Mobile must not be a reduced-functionality version of
desktop.

### Core goals

1.  Maintain customer records and outstanding balances.
2.  Record sales/purchases and payments accurately.
3.  Give the owner visibility into collections, balances, sales, and
    reports.
4.  Let the salesperson work through assigned locations/routes and
    record customer visits.
5.  Keep records synchronized through the backend.
6.  Provide a modern, consistent, readable interface in both light and
    dark themes.
7.  Preserve existing features whenever a separate feature is modified.

------------------------------------------------------------------------

## 2. Non-negotiable development rules

1.  **Do not remove existing features while fixing or adding another
    feature.** Make the smallest safe change that solves the requested
    issue.
2.  Preserve existing owner and salesperson workflows, authentication,
    permissions, Supabase integration, customer balances, transaction
    history, payments, signatures, reports, settings, and route
    management.
3.  Keep mobile and desktop feature parity. If a feature exists on
    desktop, it should also be available and usable on mobile unless
    there is a clear platform limitation.
4.  Ensure all screens respect the selected theme. Text, icons, cards,
    fields, dialogs, charts, navigation, and bottom sheets must remain
    readable in light and dark mode.
5.  Do not hard-code sample customers or transaction data into
    production screens. Data should come from the configured backend or
    the app's real data layer.
6.  Avoid placeholder, partial, or pseudocode deliverables when a
    complete file is requested.
7.  When delivering code changes, provide complete individual Dart files
    rather than snippets. The user prefers individual files, not a ZIP,
    unless a ZIP is explicitly requested.
8.  Preserve database/schema compatibility. For example, changing
    visible UI wording from **"Add Purchase"** to **"Add Sale"** must
    not casually rename existing database tables, columns, or
    identifiers.
9.  Keep currency formatting consistent everywhere, using Indian rupee
    formatting and Indian digit grouping.
10. Do not claim that code was built, analyzed, or tested unless those
    checks were actually run successfully. Clearly identify any
    verification that could not be performed.

------------------------------------------------------------------------

## 3. User roles and permissions

### 3.1 Owner

The owner is responsible for business setup and oversight. The owner
should be able to: - View business-level dashboard metrics. - Add,
search, view, edit, and delete customer records, subject to safe
handling of transaction history. - Set opening balances, including **₹0
opening balance**. - Record and review sales and payments. - Review
customer statements and transaction ledgers. - Edit received-payment
records where permitted. - View reports and collection summaries. -
Manage locations/places and reusable routes. - Assign routes/locations
to the salesperson for particular days. - Manage the salesperson/user
account and access. - Configure app settings and theme. - Export
customer statements. - Review payment methods, payment notes, bounced
cheques, and bank charges.

The owner should have an appropriate view of total money receivable,
amounts collected, and daily collection activity.

### 3.2 Salesperson

There is currently one salesperson in the intended workflow. The
salesperson should be able to: - Sign in with the correct role and
permissions. - See only the locations/routes assigned to them, not every
owner-managed location by default. - Open the assigned route/locations
and work through customers. - Search for or select a customer. - View
the customer's outstanding balance and relevant transaction details. -
Record a sale or payment. - Record a visit where no payment was
received, when applicable. - Capture a customer's signature where
required. - Record payment method and an optional note. - View the
relevant visit/transaction history needed to do the job.

The salesperson should not receive owner-only customer-management,
business-wide reporting, or route-assignment permissions unless
explicitly granted.

### 3.3 Authorization rules

-   Enforce role permissions in the backend, not only by hiding buttons
    in the UI.
-   Owner-only operations (including route assignment and administrative
    data changes) must be protected by backend authorization and
    Supabase Row Level Security (RLS).
-   Salesperson queries must be restricted to assigned locations/routes
    and the records needed for those assignments.
-   Deleted or inaccessible customer data must not leak into salesperson
    screens or payment lists.

------------------------------------------------------------------------

## 4. Customer management

The app needs a dedicated customer-management screen, separate from the
main dashboard.

### Customer records

Support at least: - Customer name - Location/place - Phone number -
Opening balance - Current balance derived from opening balance and
transactions - Transaction and payment history - Any signature/visit
information associated with the customer, where the workflow requires it

### Required behavior

-   Add a customer from the customer-management screen.
-   Keep the owner dashboard uncluttered; do **not** display the entire
    customer list on the main dashboard.
-   Provide search by customer name and location.
-   Allow editing customer details.
-   Provide a delete-customer option with safe handling of linked
    records and permissions.
-   Allow a new customer to be created with a zero opening balance.
-   Show newly added customers immediately after a successful save,
    without requiring an unexplained restart or manual refresh.
-   Customer detail screens must show accurate balance and relevant
    transaction/payment history.
-   Do not display a deleted customer's payment history in the main
    Payment screen.
-   Use appropriate confirmation for destructive actions and avoid
    silently losing financial records.

### Data integrity

-   The balance shown on a customer screen, dashboard, ledger, and
    report must agree.
-   Customer deletion must not accidentally expose orphaned history or
    corrupt totals. Define the actual delete/archive strategy
    consistently with the existing database and business requirements;
    do not silently change the database model during a UI-only fix.

------------------------------------------------------------------------

## 5. Sales / purchases

The user-facing terminology should be **Sale**: - Use **"Add Sale"**
rather than "Add Purchase" in visible UI wording wherever that action is
the sale being recorded. - Preserve existing database identifiers and
compatibility unless a separate, deliberate migration is planned.

### Sale entry requirements

-   Select the customer.
-   Enter the sale amount and the necessary transaction details
    supported by the current app.
-   Select the transaction date.
-   Support selecting a **future date** for a sale; the date picker must
    not cap the last selectable date at today. The current requested
    limit was through **31 December 2100**.
-   Retain appropriate past-date selection unless the business rules
    explicitly prohibit it.
-   Save the transaction to the backend and refresh the relevant
    customer balance, ledger, and summary views.
-   Support correcting an accidentally entered sale through a
    deliberate, permission-controlled delete/correction flow.
-   Do not allow the accidental-sale delete action to be visible but
    unusable.
-   Provide a way to remove/correct a sale that has already been paid,
    with safeguards and clear accounting consequences. Do not silently
    erase financial history.

### Transaction history cleanup

The owner requested a way to remove old purchase/sale history that has
already been paid back. Treat this as a controlled archive/cleanup
capability, not an excuse to break the audit trail. The UI and backend
must agree on whether a record is deleted, archived, or reversed.

------------------------------------------------------------------------

## 6. Payments and collection records

Payment handling is a core feature and must be reliable.

### Payment entry

A payment should support: - Customer - Amount received - Date - Payment
method - Optional note - Relevant reference/details supported by the
existing app - Signature capture where required by the workflow

### Payment methods

The user specifically requested: - Cash - Cheque / check - Online
payment, including NEFT and GPay

The chosen method must be stored and displayed accurately. **A cheque
payment must never be silently saved or displayed as cash.** The
selected method in the entry form, backend record, customer ledger,
payment section, and reports must stay consistent.

### Payment notes

-   Allow a note to be entered for a payment.
-   Display the note in the payment section and relevant
    transaction/ledger details.
-   Do not discard the note during save, edit, export, or reload.

### Payment editing

-   The owner needs the ability to edit a received payment from the
    owner ledger and customer details, with suitable authorization.
-   Editing a payment must recalculate balances and summary figures
    correctly.
-   Changes should persist after leaving and reopening the screen.

### Bounced cheque workflow

Support a way to mark a cheque as bounced: 1. Mark the cheque/payment as
bounced. 2. Ask whether to add bank charges to the customer's balance or
ignore the charges and only mark the cheque as bounced. 3. If the owner
chooses to add charges, record the amount and apply it to the customer's
balance as a separate, understandable charge/transaction. 4. If the
owner chooses to ignore charges, mark the cheque as bounced without
adding a charge. 5. Show the bounced status and any bank-charge details
in the relevant ledger/payment history. 6. Keep balance calculations and
reports consistent with the selected action.

The exact amount, date, and other fields should follow the existing data
model and be validated before saving.

------------------------------------------------------------------------

## 7. Ledger and transaction history

Transaction history should look and behave like a clear **ledger**, not
a generic unstructured list.

### Ledger expectations

-   Present entries in a readable chronological order.
-   Clearly distinguish sales/debits, payments/credits, cheque bounce
    events, and bank charges.
-   Show dates, amounts, payment methods, notes, and status when
    applicable.
-   Make the resulting balance understandable.
-   Keep typography and spacing readable on phone and desktop.
-   Use Indian rupee formatting consistently.
-   Avoid showing deleted customers' payment history on the general
    Payment screen.
-   Keep owner edit/correction actions accessible where authorized.
-   Only show the most recent **five received payments** in the
    dashboard's recent-payment preview, as previously requested. The
    full history should remain available in the relevant payment/ledger
    screen.

### Balance calculations

-   Define and apply one consistent accounting rule for opening balance,
    sales, payments, bounced cheques, and bank charges.
-   Ensure each operation updates the customer balance exactly once.
-   Prevent double-counting when a payment is edited, marked bounced, or
    reversed.
-   Make changes durable after app restart and data reload.

------------------------------------------------------------------------

## 8. Route, place, and visit management

The owner needs reusable named routes and day-specific assignments.

### Places and routes are different concepts

-   **Places** should open the place/route-location management screen.
-   **Salesman** should open salesperson/user management.
-   These must be separate destinations, not two buttons that lead to
    the same screen.

### Owner route management

The owner should be able to: - Create and manage places/locations. -
Create reusable, named routes. - Include multiple locations in a
route. - Assign different route/location combinations to different
days. - Assign the intended route(s) or locations to the salesperson. -
Edit assignments when the schedule changes. - Clearly see which
locations are assigned on each day.

### Salesperson route behavior

-   Show only locations/routes assigned to the salesperson for the
    relevant day.
-   Do not expose all places just because they exist in owner
    management.
-   Allow the salesperson to work through the assigned customer visits.
-   Record visit outcomes, including a visit with no payment where
    supported.
-   GPS/location functionality was discussed as part of the visit
    workflow; preserve it if already present, and do not add a mandatory
    permission requirement without a clear product need.
-   If location permission is unavailable, provide a clear and graceful
    experience rather than crashing.

### Data and security

-   Route templates should be reusable.
-   Daily assignments should be stored distinctly from reusable route
    definitions.
-   Prevent accidental duplicate assignments for the same
    route/location/day according to the intended business rule.
-   Enforce owner-only assignment operations through backend
    authorization/RLS.

------------------------------------------------------------------------

## 9. Dashboard and reports

### Owner dashboard

Provide a modern business overview with useful summary cards/charts and
clear navigation. The dashboard should include the relevant business
totals, such as: - Total amount receivable / outstanding - Amount
collected - Daily collection activity - Recent received payments
(maximum five in the preview) - Other existing business metrics that are
already part of the app

Do not put the full customer list on the dashboard.

### Reports

-   Keep a dedicated reports screen.
-   Reports and dashboard must work in light and dark mode.
-   Ensure charts, axes, labels, legends, card backgrounds, and text
    remain readable in both themes.
-   Use consistent calculations and rupee formatting.
-   Reports should reflect payment edits, sales, bounced cheques, bank
    charges, and customer changes.
-   Mobile reports must remain usable; prevent clipped content and
    overflow.

### Theme consistency

The user reported that dark mode was not persisting or rendering
correctly on every screen and that text was not visible on some screens.
This is a high-priority cross-app requirement, not just a dashboard fix.

------------------------------------------------------------------------

## 10. Signature capture

-   Support signature capture in the workflow where the customer needs
    to acknowledge a transaction/payment.
-   Save the signature with the appropriate record/customer workflow
    using the current backend design.
-   Reload and display saved signatures reliably.
-   The user previously reported that the signature was not visible
    after capture/save; verify the full save → retrieve → display path.
-   Provide a clear way to capture or review the signature without
    making it difficult to use on a phone.
-   Handle cancellation/empty signatures gracefully.

------------------------------------------------------------------------

## 11. Customer statements and export

-   Provide an export-customer-statement feature.
-   The user reported that statement export was not working; this must
    be treated as an end-to-end defect until a file is successfully
    generated with the correct customer and transactions.
-   Statement contents should agree with the customer ledger and include
    the relevant date, transaction type, amount, payment method,
    note/status, and balance where the current statement format supports
    them.
-   Ensure the export action reports failures clearly and does not
    pretend an export succeeded if it did not.
-   Keep this capability usable on supported phone and desktop
    platforms.

------------------------------------------------------------------------

## 12. UI/UX and visual design

The app should use a modern, polished ledger/business-management visual
system.

### Reference design

The user provided a reference image and asked for the app to match it
very closely, including the rest of the app, not just one screen. The
reference was described as a modern advanced ledger layout. Use the
supplied reference as the visual authority when it is available in the
active project context.

Previously discussed visual direction included: - Navy/dark sidebar on
desktop - Purple accents - Clean dashboard cards and charts - Readable
customer lists and customer-detail panels - Responsive mobile layouts -
Clear, ledger-style transaction history

Do not treat these notes as permission to override a newer reference
image. The latest supplied reference takes priority.

### Layout behavior

-   Desktop may use a sidebar and wider multi-panel layouts.
-   Mobile should use a mobile-appropriate navigation pattern, including
    bottom tabs where part of the established design.
-   Main dashboard should not be overloaded with the entire customer
    list.
-   Keep Places management and Salesman management distinct.
-   Make forms, buttons, dialogs, cards, tables, and navigation
    responsive.
-   Prevent overflow, clipped text, and controls extending off-screen.
-   Ensure all labels and amounts remain legible in all themes.
-   Keep feature parity across phone and desktop.

### Wording and terminology

-   Visible sale action: **Add Sale**, not **Add Purchase**.
-   Use consistent names for customer, sale, payment, route, place, and
    salesperson concepts.
-   Do not rename database identifiers merely to match UI wording.

------------------------------------------------------------------------

## 13. Theme and readability

-   Support light and dark mode.
-   The selected theme should persist and be applied consistently across
    every screen, dialog, modal, bottom sheet, menu, chart, and form.
-   Do not hard-code colors that make text disappear in one theme.
-   Use theme-aware colors for surfaces, borders, text, icons, inputs,
    and charts.
-   Check contrast for secondary text and disabled states as well as
    primary text.
-   Ensure a theme change updates every screen, including the
    salesperson side.
-   Persist the user's chosen theme across app restarts, according to
    the app's existing theme-setting design.
-   Avoid screens that independently default to light mode when the rest
    of the app is dark.

------------------------------------------------------------------------

## 14. Currency, dates, and data formatting

### Currency

-   Use Indian rupees (₹).
-   Use Indian digit grouping (for example, `₹1,23,456.78` where
    decimals are relevant).
-   Use the existing `lib/services/currency_formatter.dart` and
    `CurrencyFormatter.rupees(...)` / `.format(...)` APIs where
    appropriate instead of implementing different formatters in
    individual screens.
-   Use consistent formatting in dashboard totals, customer balances,
    sales, payments, ledger entries, reports, forms, and statements.

### Dates

-   Use consistent, human-readable date formatting throughout the app.
-   Sale entry must allow future dates through 31 December 2100 as
    requested.
-   Ensure date selection, storage, display, and report filtering use
    consistent date semantics and do not shift dates unexpectedly
    because of timezone conversion.

------------------------------------------------------------------------

## 15. Backend, Supabase, and persistence

Supabase is the configured backend. The project ID recorded during
development is `rxjexwtdhopkltrrlbnd`.

### General requirements

-   Persist customers, balances/transactions, payments, notes, payment
    methods, signatures, route definitions, daily assignments, visit
    outcomes, and other existing app data through the established
    backend.
-   Use the existing service/data-access layer rather than duplicating
    raw database logic across screens.
-   Keep loading, success, empty, and error states understandable.
-   Refresh the relevant UI after successful mutations.
-   Make sure a successful save is reflected in all affected screens and
    reports.
-   Handle network/backend failures without falsely showing success.
-   Keep schema changes explicit and migration-safe.
-   Enforce RLS and role access for sensitive business records.

### Known persistence defects reported

-   Customer save succeeded but the new customer did not appear in
    customer management.
-   Saved signature was not visible.
-   Payment updates did not show.
-   A cheque payment was being stored/displayed as cash.
-   Customer statement export did not work.
-   Some delete/correction actions were not selectable.
-   Dark mode and readable text were inconsistent across screens.

These are end-to-end data-flow issues: test form entry, persistence,
retrieval, and display, not only the button handler.

### Configuration/security

-   Development has used a `SUPABASE_PUBLISHABLE_KEY` supplied through
    `--dart-define`.
-   Do not hard-code secret/service-role keys into the client
    application or commit credentials.
-   Preserve existing environment/configuration conventions unless
    deliberately migrating them.
-   Never weaken RLS just to make a UI screen work.

------------------------------------------------------------------------

## 16. Authentication and settings

-   Preserve existing authentication and role-aware navigation.
-   Ensure owner and salesperson users land on the correct screens.
-   Protect owner-only actions.
-   Keep app settings and theme preferences functional.
-   Maintain the established Supabase authentication/data flow.
-   Do not remove sign-in, sign-out, or session handling when changing
    unrelated screens.

------------------------------------------------------------------------

## 17. Platform support and distribution

### Platforms

-   Android
-   iOS
-   macOS
-   Windows

The app should be usable on phones and PCs.

### Build and delivery goals

-   Produce a client-sendable Android APK.
-   Provide a Windows build/version as requested.
-   Keep macOS development/build support working.
-   Do not claim a platform build is ready until it has been built and,
    where possible, launched/tested on that platform.

### Known environment/build concerns

-   A Windows machine reported a missing `VCRUNTIME140_1.dll`; the
    likely distribution concern is the Microsoft Visual C++ runtime
    dependency. Package/document prerequisites appropriately and verify
    on a clean Windows environment.
-   Previous Flutter/macOS build work encountered deployment-target and
    CocoaPods/framework issues, which were later followed by a
    successful macOS debug build.
-   Android tooling/SDK and simulator availability have been issues in
    the development environment at different times.
-   Flutter dependency upgrades may be constrained by current package
    compatibility. Do not upgrade dependencies blindly as part of an
    unrelated UI fix.

------------------------------------------------------------------------

## 18. Technical project context

-   Flutter application folder/project name: `horizon`
-   Main development machine: MacBook Air with Apple M4
-   Main implementation language: Dart / Flutter
-   Backend: Supabase
-   Currency formatter: `lib/services/currency_formatter.dart`
-   The app has separate owner and salesperson experiences, customer
    management, sales/payment flows, routes/places, reports,
    theme/settings, and related service files.

### Development commands used

Example macOS run command:

``` bash
flutter run -d macos --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Use the actual local development key securely; do not paste private
credentials into public documentation or source control.

Common verification commands (run from the project root):

``` bash
flutter pub get
flutter analyze
flutter test
```

Then build/test the relevant target using the Flutter tooling installed
for that platform. Do not treat a clean `flutter analyze` as proof of
runtime correctness; verify key workflows manually as well.

------------------------------------------------------------------------

## 19. Known defects and regression risks

Treat these as reported issues to verify, not as proof that they remain
unfixed in the latest code.

  -----------------------------------------------------------------------
  Area                                Reported issue / required
                                      verification
  ----------------------------------- -----------------------------------
  Theme                               Dark mode did not persist or apply
                                      consistently across every screen.

  Readability                         Text was invisible or low-contrast
                                      on some screens.

  Customer management                 Saved customer did not immediately
                                      appear in the list.

  Signatures                          Saved/captured signature was not
                                      visible afterward.

  Payments                            Payment updates did not appear
                                      consistently.

  Payment method                      Cheque was being saved/displayed as
                                      cash.

  Customer statement                  Export action was not working.

  Sale correction                     Accidental-sale delete option was
                                      not selectable.

  Paid history                        Need a safe way to remove/archive
                                      paid-off old sale history.

  Deleted customers                   Their payment history must not
                                      appear on the main Payment screen.

  Route management                    Owner needs named reusable routes
                                      and different multi-location
                                      assignments by day.

  Route permissions                   Salesperson must see only assigned
                                      locations.

  Places vs Salesman                  Must navigate to separate
                                      management screens.

  Responsive UI                       Mobile must match desktop in
                                      functionality and avoid overflow.

  Windows distribution                Missing `VCRUNTIME140_1.dll` was
                                      reported on a Windows machine.

  Recent payments                     Dashboard preview should show only
                                      the latest five received payments.

  Date picker                         New Sale must allow future dates
                                      through 31 December 2100.
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 20. Acceptance checklist

A release should not be considered ready until the applicable items
below have been verified.

### Customer workflow

-   [ ] Owner can create a customer with a positive, negative (if
    supported by the established accounting rules), or zero opening
    balance.
-   [ ] Saved customer appears in the list without a restart.
-   [ ] Search works by name and location.
-   [ ] Customer details and balances are accurate after reload.
-   [ ] Editing and deleting customers follow the intended safe
    data-handling rules.
-   [ ] Deleted customers' payment history is absent from the general
    Payment screen.

### Sale workflow

-   [ ] UI says **Add Sale** where appropriate.
-   [ ] A sale can be saved for a past, current, and future date.
-   [ ] Future-date selection extends through 31 December 2100.
-   [ ] Customer balance, ledger, dashboard, and reports update
    consistently.
-   [ ] Accidental-sale correction/deletion is selectable and protected.
-   [ ] Paid-off history cleanup does not silently corrupt the audit
    trail.

### Payment workflow

-   [ ] Cash, cheque, NEFT, and GPay can be selected and saved
    accurately.
-   [ ] Payment notes persist and display.
-   [ ] Owner can edit a received payment where required.
-   [ ] Edits update balance and reports exactly once.
-   [ ] Cheque bounce can be recorded.
-   [ ] Owner can choose whether to add bank charges or ignore them.
-   [ ] Bounce status and charge treatment are visible in the ledger.
-   [ ] Latest-payment dashboard preview shows at most five entries.

### Signature and export

-   [ ] Signature can be captured, saved, retrieved, and displayed.
-   [ ] Customer statement export produces a usable file with correct
    customer/transaction data.
-   [ ] Export failures are reported accurately.

### Routes and visits

-   [ ] Owner can manage places separately from salesperson accounts.
-   [ ] Owner can create named reusable routes with multiple locations.
-   [ ] Owner can assign different routes/locations for different days.
-   [ ] Salesperson sees only assigned locations for the relevant day.
-   [ ] Visit/payment/no-payment records work as intended.
-   [ ] Location/GPS permission failures do not crash the app.

### UI and accessibility

-   [ ] Reference design is followed across the app.
-   [ ] Light and dark themes work across owner and salesperson screens.
-   [ ] Theme preference persists after restart.
-   [ ] Text and controls are readable in both themes.
-   [ ] No overflow/clipped labels on phone or desktop.
-   [ ] Desktop and mobile retain feature parity.
-   [ ] Currency formatting is consistent throughout.

### Backend and release

-   [ ] Data persists through Supabase and is retrieved correctly after
    reload.
-   [ ] Owner/salesperson permissions are enforced in backend policies.
-   [ ] No secret/service-role key is embedded in the client.
-   [ ] `flutter analyze` is run and relevant issues are resolved.
-   [ ] Relevant platform builds succeed.
-   [ ] Core workflows are manually tested on the target platforms.
-   [ ] Android APK and Windows deliverables are tested before being
    sent to a client.

------------------------------------------------------------------------

## 21. Suggested end-to-end regression test

Use a dedicated test business/customer dataset, not real customer data.

1.  Sign in as owner.
2.  Create a customer with ₹0 opening balance and verify the customer
    appears immediately.
3.  Add a sale for that customer using a future date; verify the date
    and balance.
4.  Record a cash payment with a note; verify the ledger and balance.
5.  Record a cheque payment and verify it remains a cheque in every
    screen.
6.  Edit a received payment and verify the balance is recalculated
    correctly.
7.  Mark a cheque as bounced; test both bank-charge choices.
8.  Capture a signature and verify it remains visible after reopening
    the record.
9.  Export the customer statement and compare it against the ledger.
10. Create two named routes with multiple places and assign different
    locations for different days.
11. Sign in as salesperson and verify only the assigned locations
    appear.
12. Record a visit with payment and, where supported, a visit without
    payment.
13. Delete/archive a test customer or correct an accidental sale; verify
    the agreed history behavior.
14. Switch between light and dark themes and navigate through every
    major screen.
15. Repeat key workflows on a phone-sized layout and a desktop-sized
    layout.
16. Verify dashboard totals, latest-five payment preview, customer
    balances, and reports all agree.

------------------------------------------------------------------------

## 22. Requirement status and open implementation details

This document consolidates the product requirements and reported issues
known so far. It does not assume every requirement is implemented.
Before changing the database or deleting data, inspect the current
schema and code.

The following implementation details should be resolved by examining the
current codebase/schema rather than guessing: - Exact table and column
names for customers, sales, payments, signatures, routes, assignments,
and visits. - Whether paid-history cleanup should archive, reverse, or
permanently delete records. - The precise accounting treatment for
cheque bounce and bank charges. - Exact statement export format and
platform-specific file-sharing behavior. - The current implementation
status of GPS tracking/location capture. - The final
component-by-component mapping to the latest visual reference image.

When in doubt, preserve existing working behavior, make a minimal
targeted change, and verify that the change has not regressed another
workflow.

------------------------------------------------------------------------

**End of specification.**
