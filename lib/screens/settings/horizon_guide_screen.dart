import 'package:flutter/material.dart';

import '../../services/tutorial_service.dart';

class HorizonGuideScreen extends StatefulWidget {
  const HorizonGuideScreen({super.key, required this.role});
  final String role;
  @override
  State<HorizonGuideScreen> createState() => _HorizonGuideScreenState();
}

class _HorizonGuideScreenState extends State<HorizonGuideScreen> {
  final _search = TextEditingController();
  String _category = 'Getting Started';
  String? _selectedId;
  Set<String> _completed = {};
  List<String> _recent = [];

  List<_GuideLesson> get _lessons => _allLessons
      .where((lesson) => lesson.roles.contains(widget.role))
      .toList();
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final completed = await HorizonGuideProgress.completedLessons();
    final recent = await HorizonGuideProgress.recentLessons();
    if (mounted) {
      setState(() {
        _completed = completed;
        _recent = recent;
      });
    }
  }

  Future<void> _open(_GuideLesson lesson) async {
    setState(() => _selectedId = lesson.id);
    await HorizonGuideProgress.markOpened(lesson.id);
    if (mounted) {
      setState(() {
        _recent.remove(lesson.id);
        _recent.insert(0, lesson.id);
      });
    }
  }

  Future<void> _toggle(_GuideLesson lesson) async {
    final done = !_completed.contains(lesson.id);
    await HorizonGuideProgress.setLessonCompleted(lesson.id, done);
    if (mounted) {
      setState(
        () => done ? _completed.add(lesson.id) : _completed.remove(lesson.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final categories = _lessons.map((e) => e.category).toSet().toList();
    final visible = _lessons
        .where(
          (lesson) => (query.isEmpty
              ? lesson.category == _category
              : lesson.searchable.contains(query)),
        )
        .toList();
    final selected =
        _lessons.where((l) => l.id == _selectedId).firstOrNull ??
        visible.firstOrNull;
    final compact = MediaQuery.sizeOf(context).width < 760;
    final navigation = _GuideNavigation(
      categories: categories,
      selected: _category,
      onSelect: (value) => setState(() {
        _category = value;
        _search.clear();
        _selectedId = null;
      }),
    );
    final lessons = _LessonList(
      lessons: visible,
      completed: _completed,
      onOpen: _open,
    );
    final content = selected == null
        ? const Center(child: Text('No matching guide found.'))
        : _LessonContent(
            lesson: selected,
            completed: _completed.contains(selected.id),
            onToggle: () => _toggle(selected),
          );
    return Scaffold(
      appBar: AppBar(title: const Text('Sydex Guide')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search guides, features, and tasks',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            if (compact)
              SizedBox(
                height: 42,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: categories
                      .map(
                        (c) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(c),
                            selected: c == _category && query.isEmpty,
                            onSelected: (_) => setState(() {
                              _category = c;
                              _search.clear();
                            }),
                          ),
                        ),
                      )
                      .toList(),
                ),
              )
            else
              const SizedBox(),
            const SizedBox(height: 8),
            Expanded(
              child: compact
                  ? ListView(
                      children: [
                        if (query.isEmpty)
                          _ContinueLearning(
                            recent: _recent,
                            all: _lessons,
                            onOpen: _open,
                          ),
                        ...lessons.buildItems(context),
                        if (selected != null) const Divider(),
                        if (selected != null) content,
                      ],
                    )
                  : Row(
                      children: [
                        SizedBox(width: 190, child: navigation),
                        const VerticalDivider(),
                        SizedBox(width: 270, child: lessons),
                        const VerticalDivider(),
                        Expanded(child: content),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideNavigation extends StatelessWidget {
  const _GuideNavigation({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) => ListView(
    children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text(
          'CATEGORIES',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
        ),
      ),
      ...categories.map(
        (c) => ListTile(
          dense: true,
          selected: c == selected,
          leading: Icon(_categoryIcon(c), size: 19),
          title: Text(c),
          onTap: () => onSelect(c),
        ),
      ),
    ],
  );
}

class _LessonList extends StatelessWidget {
  const _LessonList({
    required this.lessons,
    required this.completed,
    required this.onOpen,
  });
  final List<_GuideLesson> lessons;
  final Set<String> completed;
  final ValueChanged<_GuideLesson> onOpen;
  List<Widget> buildItems(BuildContext context) => lessons
      .map(
        (l) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            completed.contains(l.id)
                ? Icons.check_circle
                : Icons.menu_book_outlined,
            color: completed.contains(l.id)
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          title: Text(l.title),
          subtitle: Text(
            '${l.minutes} min · ${l.description}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => onOpen(l),
        ),
      )
      .toList();
  @override
  Widget build(BuildContext context) => ListView(children: buildItems(context));
}

class _LessonContent extends StatelessWidget {
  const _LessonContent({
    required this.lesson,
    required this.completed,
    required this.onToggle,
  });
  final _GuideLesson lesson;
  final bool completed;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    children: [
      Text(lesson.category, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      Text(
        lesson.title,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 12),
      Text(lesson.description),
      const SizedBox(height: 20),
      _HorizonDemoPreview(lessonId: lesson.id),
      const SizedBox(height: 6),
      Text(
        'Demo Sydex screen — example data only',
        style: Theme.of(context).textTheme.labelSmall,
      ),
      const SizedBox(height: 20),
      const Text(
        'Before you begin',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      Text(lesson.before),
      const SizedBox(height: 20),
      const Text('Step-by-step', style: TextStyle(fontWeight: FontWeight.w800)),
      ...lesson.steps.asMap().entries.map(
        (e) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(radius: 13, child: Text('${e.key + 1}')),
          title: Text(e.value),
        ),
      ),
      const SizedBox(height: 16),
      if (lesson.important != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(lesson.important!),
          ),
        ),
      FilledButton.icon(
        onPressed: onToggle,
        icon: Icon(completed ? Icons.check : Icons.check_circle_outline),
        label: Text(completed ? 'Completed' : 'Mark as complete'),
      ),
    ],
  );
}

class _ContinueLearning extends StatelessWidget {
  const _ContinueLearning({
    required this.recent,
    required this.all,
    required this.onOpen,
  });
  final List<String> recent;
  final List<_GuideLesson> all;
  final ValueChanged<_GuideLesson> onOpen;
  @override
  Widget build(BuildContext context) {
    final lessons = recent
        .map((id) => all.where((l) => l.id == id).firstOrNull)
        .whereType<_GuideLesson>()
        .toList();
    return lessons.isEmpty
        ? const SizedBox()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CONTINUE LEARNING',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
              ),
              ...lessons.map(
                (l) => ListTile(
                  title: Text(l.title),
                  trailing: const Icon(Icons.arrow_forward),
                  onTap: () => onOpen(l),
                ),
              ),
            ],
          );
  }
}

/// A privacy-safe visual reference for every lesson. It deliberately mirrors
/// Horizon's layout without ever rendering records from the signed-in account.
class _HorizonDemoPreview extends StatelessWidget {
  const _HorizonDemoPreview({required this.lessonId});
  final String lessonId;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = switch (lessonId) {
      'dashboard' => 'Dashboard',
      'customers' => 'Customers',
      'payment' => 'Receive payment',
      'route' => 'Places & routes',
      'visit' => "Today's customers",
      'reports' => 'Reports',
      _ => 'Horizon',
    };
    final lines = switch (lessonId) {
      'payment' => const [
        'Sample Customer',
        'Amount received',
        'Payment method',
      ],
      'route' => const [
        'North District',
        '12 customers selected',
        'Assign to executive',
      ],
      'visit' => const ['Sample Customer A', 'Not visited', 'Record visit'],
      'customers' => const [
        'Sample Customer A',
        'West District',
        'Balance: 1,250.00',
      ],
      'reports' => const ['Collections', 'Outstanding', 'Export report'],
      'dashboard' => const [
        'Total receivable',
        "Today's collections",
        'Payment overview',
      ],
      _ => const ['Customers', 'Payments', 'Settings'],
    };
    return Container(
      height: 188,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.menu, size: 17, color: colors.primary),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              Icon(Icons.more_horiz, color: colors.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: 12),
          if (lessonId == 'dashboard' || lessonId == 'reports')
            Row(
              children: List.generate(
                3,
                (index) => Expanded(
                  child: Container(
                    height: 44,
                    margin: EdgeInsets.only(right: index == 2 ? 0 : 8),
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      index == 0
                          ? '1,250'
                          : index == 1
                          ? '480'
                          : '24',
                      style: TextStyle(
                        color: colors.onPrimaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            ...lines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Container(
                  height: 27,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    line,
                    style: TextStyle(fontSize: 10, color: colors.onSurface),
                  ),
                ),
              ),
            ),
          const Spacer(),
          Container(
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              lessonId == 'payment' ? 'Save payment' : 'Continue',
              style: TextStyle(
                color: colors.onPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideLesson {
  const _GuideLesson(
    this.id,
    this.category,
    this.title,
    this.description,
    this.before,
    this.steps,
    this.minutes,
    this.roles, [
    this.important,
  ]);
  final String id, category, title, description, before;
  final List<String> steps;
  final int minutes;
  final Set<String> roles;
  final String? important;
  String get searchable =>
      '$category $title $description ${steps.join(' ')}'.toLowerCase();
}

IconData _categoryIcon(String c) => switch (c) {
  'Dashboard' => Icons.dashboard_outlined,
  'Customer Management' => Icons.people_alt_outlined,
  'Payments & Collections' => Icons.payments_outlined,
  'Routes & Visits' => Icons.route_outlined,
  'Reports & Analytics' => Icons.insights_outlined,
  _ => Icons.school_outlined,
};
final _allLessons = <_GuideLesson>[
  const _GuideLesson(
    'start',
    'Getting Started',
    'Start with Horizon',
    'Understand the main areas of your workspace.',
    'Sign in to your assigned Horizon account.',
    [
      'Open the dashboard.',
      'Use the sidebar or bottom navigation to move between features.',
      'Open Settings to adjust your preferences.',
    ],
    2,
    {'owner', 'salesman'},
  ),
  const _GuideLesson(
    'dashboard',
    'Dashboard',
    'Understand the dashboard',
    'Review business performance and today’s work at a glance.',
    'Your account must be signed in.',
    [
      'Review receivables and collection summaries.',
      'Choose a date period for the chart.',
      'Open a linked card to see its source records.',
    ],
    2,
    {'owner', 'salesman'},
  ),
  const _GuideLesson(
    'customers',
    'Customer Management',
    'Add and manage customers',
    'Keep customer details and their ledger in one place.',
    'Owners need permission to add or edit customers.',
    [
      'Open Customers.',
      'Use Add customer and save the contact details.',
      'Open a customer to review balance and history.',
    ],
    3,
    {'owner'},
  ),
  const _GuideLesson(
    'payment',
    'Payments & Collections',
    'Record a payment',
    'Record only money that has actually been received.',
    'Select the customer and confirm the amount before saving.',
    [
      'Open the customer or Payments.',
      'Choose the payment method and enter the amount.',
      'Review the balance change, then save.',
    ],
    3,
    {'owner', 'salesman'},
    'Showing a QR code does not confirm a payment. Record it only after checking the payment.',
  ),
  const _GuideLesson(
    'route',
    'Routes & Visits',
    'Build an assigned route',
    'Combine complete locations with individual customers for a daily route.',
    'Owners need an existing customer list.',
    [
      'Open Places & Routes.',
      'Add locations or individual customers.',
      'Save and assign the route to the executive.',
    ],
    3,
    {'owner'},
  ),
  const _GuideLesson(
    'visit',
    'Routes & Visits',
    'Record a customer visit',
    'Track visits independently from payment collection.',
    'A customer must be assigned to your daily customer list.',
    [
      'Open the customer.',
      'Record the visit outcome.',
      'Add a payment only if money was received.',
    ],
    2,
    {'salesman'},
  ),
  const _GuideLesson(
    'reports',
    'Reports & Analytics',
    'Use reports and payment history',
    'Review collections and outstanding amounts over a selected period.',
    'Owner access is required.',
    [
      'Open Reports.',
      'Choose a date filter.',
      'Use payment history for transaction details.',
    ],
    2,
    {'owner'},
  ),
];
