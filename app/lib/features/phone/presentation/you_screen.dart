import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../multichat/presentation/multi_chat_screen.dart';
import '../../prompts/presentation/prompt_list_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../usage/presentation/plan_usage_meter.dart';
import '../../usage/presentation/usage_screen.dart';

/// The phone shell's "You" tab: plan meters on top, then the app-level screens.
class YouScreen extends StatelessWidget {
  const YouScreen({super.key, required this.creds});
  final Creds creds;

  void _go(BuildContext context, Widget screen) => Navigator.of(context).push(sharedAxisRoute(screen));

  @override
  Widget build(BuildContext context) {
    final items = <(String, IconData, Widget Function())>[
      ('Usage', Icons.insights_outlined, () => UsageScreen(creds: creds)),
      ('Prompt library', Icons.bookmarks_outlined, () => PromptListScreen(creds: creds)),
      ('Multi-chat', Icons.grid_view_outlined, () => MultiChatScreen(creds: creds)),
      ('Settings', Icons.settings_outlined, () => SettingsScreen(creds: creds)),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('You')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.md, Spacing.sm),
            child: PlanUsageMeter(
              creds: creds,
              onTap: () => _go(context, UsageScreen(creds: creds)),
            ),
          ),
          for (final (title, icon, screen) in items)
            ListTile(
              leading: Icon(icon),
              title: Text(title),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _go(context, screen()),
            ),
        ],
      ),
    );
  }
}
