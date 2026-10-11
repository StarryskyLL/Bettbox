import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/override_profile.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Rule types offered here. The shared editor can handle every [RuleAction],
/// but this page is meant for writing ordinary routing rules quickly, so the
/// list is deliberately limited to the common cases.
const _supportedActions = <RuleAction>[
  RuleAction.DOMAIN,
  RuleAction.DOMAIN_SUFFIX,
  RuleAction.DOMAIN_WILDCARD,
  RuleAction.DOMAIN_KEYWORD,
  RuleAction.DOMAIN_REGEX,
  RuleAction.IP_CIDR,
  RuleAction.DST_PORT,
  RuleAction.PROCESS_NAME,
  RuleAction.GEOSITE,
  RuleAction.GEOIP,
];

/// How long the filled-check confirmation stays on the apply action.
const _appliedFeedbackDuration = Duration(milliseconds: 1500);

/// Global split-routing rules: user-authored rules that are appended ahead of
/// the subscription rules on every core start, independent of any profile.
///
/// Reuses the rule editor already used by the profile override page
/// ([AddRuleDialog]) and follows the script page's list layout, so this adds a
/// feature without introducing a second visual language.
class SplitRoutingView extends ConsumerStatefulWidget {
  const SplitRoutingView({super.key});

  @override
  ConsumerState<SplitRoutingView> createState() => SplitRoutingViewState();
}

class SplitRoutingViewState extends ConsumerState<SplitRoutingView> {
  /// Target list for the shared rule editor.
  ///
  /// Global rules are profile-independent, so a profile is never required:
  /// with no active profile this stays empty and the editor falls back to the
  /// built-in targets it derives from [RuleTarget] (GLOBAL / DIRECT / REJECT).
  ClashConfigSnippet _snippet = const ClashConfigSnippet();
  bool _applied = false;
  Timer? _appliedTimer;

  @override
  void dispose() {
    _appliedTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSnippet());
  }

  void _loadSnippet() {
    final profileId = ref.read(currentProfileIdProvider);
    if (profileId == null) {
      return;
    }
    _loadSnippetFor(profileId);
  }

  Future<void> _loadSnippetFor(String profileId) async {
    try {
      final rawConfig = await globalState.getProfileConfig(profileId);
      if (!mounted) {
        return;
      }
      setState(() => _snippet = ClashConfigSnippet.fromJson(rawConfig));
    } catch (e) {
      // The core may not be running (no profile applied yet). Rule authoring
      // still works with the built-in targets, so this is not an error state.
      commonPrint.log('SplitRouting: failed to load profile snippet: $e');
    }
  }

  Future<void> _handleAddOrUpdate([GlobalRule? rule]) async {
    // Always refresh before opening the editor: the active profile, and with it
    // the set of policy groups offered as rule targets, can change while this
    // page stays open.
    final profileId = ref.read(currentProfileIdProvider);
    if (profileId != null) {
      await _loadSnippetFor(profileId);
    }
    if (!mounted) {
      return;
    }
    final res = await globalState.showCommonDialog<Rule>(
      child: AddRuleDialog(
        snippet: _snippet,
        rule: rule?.asRule,
        actions: _supportedActions,
      ),
    );
    if (res == null) {
      return;
    }
    final notifier = ref.read(globalRulesProvider.notifier);
    if (rule == null) {
      notifier.setRule(GlobalRule.value(res.value));
    } else {
      notifier.setRule(rule.mergeEdited(res));
    }
  }

  Future<void> _handleDelete(GlobalRule rule) async {
    final res = await globalState.showMessage(
      message: TextSpan(
        text: appLocalizations.deleteTip(appLocalizations.rule),
      ),
    );
    if (res != true) {
      return;
    }
    ref.read(globalRulesProvider.notifier).deleteById(rule.id);
  }

  void _handleApply() {
    globalState.appController.setupClashConfigDebounce();
    globalState.showNotifier(appLocalizations.splitRoutingApplied);
    // Brief filled-check feedback so it is obvious the tap registered; the
    // rules themselves are written by the debounced setup above.
    setState(() => _applied = true);
    _appliedTimer?.cancel();
    _appliedTimer = Timer(_appliedFeedbackDuration, () {
      if (mounted) {
        setState(() => _applied = false);
      }
    });
  }

  Widget _buildContent() {
    final rules = ref.watch(globalRulesProvider);
    if (rules.isEmpty) {
      return NullStatus(
        label: appLocalizations.nullTip(appLocalizations.splitRouting),
      );
    }
    return CommonScrollBar(
      controller: null,
      child: ListView(
        padding: const EdgeInsets.all(16).copyWith(bottom: 16 + 64),
        children: [
          CommonCard(
            type: CommonCardType.filled,
            radius: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < rules.length; i++) ...[
                  _SplitRoutingItem(
                    key: ObjectKey(rules[i]),
                    rule: rules[i],
                    onEdit: () => _handleAddOrUpdate(rules[i]),
                    onDelete: () => _handleDelete(rules[i]),
                    onToggle: (value) {
                      ref
                          .read(globalRulesProvider.notifier)
                          .setRule(rules[i].copyWith(enable: value));
                    },
                  ),
                  if (i != rules.length - 1)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appSettingProvider.select((state) => state.locale));
    final hasRules = ref.watch(
      globalRulesProvider.select((state) => state.isNotEmpty),
    );
    return CommonScaffold(
      // Always available: the empty state is exactly when the first rule has
      // to be added. Matches the script page, which also always shows it.
      floatingActionButton: FloatingActionButton(
        onPressed: () => _handleAddOrUpdate(),
        child: const Icon(Icons.add),
      ),
      actions: [
        if (hasRules)
          IconButton(
            onPressed: _handleApply,
            tooltip: appLocalizations.splitRoutingApply,
            icon: Icon(_applied ? Icons.check_circle : Icons.check),
          ),
      ],
      body: _buildContent(),
      title: appLocalizations.splitRouting,
    );
  }
}

class _SplitRoutingItem extends StatelessWidget {
  final GlobalRule rule;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  const _SplitRoutingItem({
    super.key,
    required this.rule,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return ListItem(
      onTap: onEdit,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: EmojiText(
        rule.value,
        style: context.textTheme.bodyMedium?.toJetBrainsMono,
      ),
      leading: Switch(value: rule.enable, onChanged: onToggle),
      trailing: CommonPopupBox(
        targetBuilder: (open) {
          return IconButton(
            onPressed: () {
              open();
            },
            tooltip: appLocalizations.more,
            icon: const Icon(Icons.more_vert),
          );
        },
        popup: CommonPopupMenu(
          items: [
            PopupMenuItemData(
              icon: Icons.edit,
              label: appLocalizations.edit,
              onPressed: onEdit,
            ),
            PopupMenuItemData(
              icon: Icons.delete,
              label: appLocalizations.delete,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
