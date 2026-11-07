import 'package:flutter/material.dart';

import '../../services/tutorial_service.dart';

class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key, required this.role});
  final String role;

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  final _controller = PageController();
  int _page = 0;
  bool _doNotShowAgain = false;

  List<_TutorialStep> get _steps => widget.role == 'owner'
      ? const [
          _TutorialStep(
            Icons.dashboard_outlined,
            'Your business at a glance',
            'Use the dashboard to review receivables, collections, overdue balances, and team activity.',
          ),
          _TutorialStep(
            Icons.people_alt_outlined,
            'Manage customers',
            'Add customers, review their ledger, and record sales, returns, or payments from one place.',
          ),
          _TutorialStep(
            Icons.route_outlined,
            'Build daily routes',
            'Create routes by location, add individual customers, then assign the combined route to your team.',
          ),
          _TutorialStep(
            Icons.insights_outlined,
            'Stay in control',
            'Use reports, payment history, and settings to keep your workspace accurate and secure.',
          ),
        ]
      : const [
          _TutorialStep(
            Icons.home_outlined,
            'Plan your day',
            'Your home screen shows the customers assigned to you and your visit progress.',
          ),
          _TutorialStep(
            Icons.people_alt_outlined,
            'Visit customers',
            'Open a customer to review the balance, record a visit, and see payment history.',
          ),
          _TutorialStep(
            Icons.payments_outlined,
            'Receive payments',
            'Record cash, cheque, or online payments only after confirming the amount with the customer.',
          ),
          _TutorialStep(
            Icons.receipt_long_outlined,
            'Keep a clear record',
            'Share receipts and check your collection history whenever you need it.',
          ),
        ];

  Future<void> _finish() async {
    await TutorialService.setDoNotShowAgain(_doNotShowAgain);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('How to use Sydex'),
        actions: [TextButton(onPressed: _finish, child: const Text('Skip'))],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _steps.length,
                  onPageChanged: (value) => setState(() => _page = value),
                  itemBuilder: (_, index) {
                    final item = _steps[index];
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 92,
                          height: 92,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            item.icon,
                            color: Theme.of(context).colorScheme.primary,
                            size: 44,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          item.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          item.description,
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyLarge?.copyWith(height: 1.45),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _steps.length,
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.all(4),
                    width: index == _page ? 20 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: index == _page
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _doNotShowAgain,
                onChanged: (value) =>
                    setState(() => _doNotShowAgain = value ?? false),
                title: const Text('Do not show again when I log in'),
              ),
              Row(
                children: [
                  if (_page > 0)
                    TextButton(
                      onPressed: () => _controller.previousPage(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      ),
                      child: const Text('Back'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _page == _steps.length - 1
                        ? _finish
                        : () => _controller.nextPage(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                          ),
                    child: Text(_page == _steps.length - 1 ? 'Finish' : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TutorialStep {
  const _TutorialStep(this.icon, this.title, this.description);
  final IconData icon;
  final String title;
  final String description;
}
