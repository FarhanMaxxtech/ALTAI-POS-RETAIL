import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../domain/staff.dart';

/// Pick the store this tablet is in. Every basket is checked against it.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key, required this.loadStores, required this.onPicked});

  /// The stores to choose from.
  final Future<List<Store>> Function() loadStores;
  final void Function(Store store) onPicked;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  List<Store>? _stores;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final stores = await widget.loadStores();
      if (mounted) setState(() => _stores = stores);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final stores = _stores;
    final error = _error;
    return Scaffold(
      appBar: AltaiAppBar(
        title: 'Set location',
        onBack: Navigator.of(context).canPop() ? () => Navigator.of(context).pop() : null,
      ),
      body: error != null
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(D.space6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AltaiNotice(error),
                      const SizedBox(height: D.space4),
                      AltaiButton('Try again', onPressed: _load, icon: Icons.refresh_rounded),
                    ],
                  ),
                ),
              ),
            )
          : stores == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(D.space6),
                  children: [
                    Text('Which store is this tablet in?', style: AltaiType.heading.copyWith(color: c.ink)),
                    Text(
                      'Every item scanned here is checked against this store.',
                      style: AltaiType.body.copyWith(color: c.inkMuted),
                    ),
                    const SizedBox(height: D.space4),
                    if (stores.isEmpty)
                      const AltaiNotice('This account has no stores. Ask your manager.', warning: true),
                    for (final s in stores)
                      Padding(
                        padding: const EdgeInsets.only(bottom: D.space3),
                        child: _StoreTile(store: s, onTap: () => widget.onPicked(s)),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _StoreTile extends StatelessWidget {
  const _StoreTile({required this.store, required this.onTap});

  final Store store;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Material(
      color: c.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(D.radiusMd),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 80),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: D.space6, vertical: D.space3),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(D.radiusMd)),
                  child: Icon(Icons.storefront_rounded, color: c.brandInk),
                ),
                const SizedBox(width: D.space4),
                Expanded(
                  child: Text(store.name, style: AltaiType.bodyStrong.copyWith(color: c.ink)),
                ),
                Icon(Icons.chevron_right_rounded, size: 28, color: c.inkMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
