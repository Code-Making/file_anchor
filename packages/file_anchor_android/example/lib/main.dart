import 'package:file_anchor/file_anchor.dart';
import 'package:flutter/material.dart';

void main() => runApp(const DemoApp());

/// A deliberately dependency-free demonstration of durable access.
///
/// Persisting the token is the caller's job, so this app shows it instead of
/// storing it: copy the token, kill the app, relaunch, paste it back and press
/// Resolve. If listing still works, access genuinely survived the process --
/// which is the whole claim of the package.
class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'file_anchor',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const DemoPage(),
      );
}

/// The demo screen.
class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final TextEditingController _tokenField = TextEditingController();
  Anchor? _anchor;
  List<AnchorEntry> _entries = const [];
  String _status = 'Pick a folder to begin.';

  @override
  void dispose() {
    _tokenField.dispose();
    super.dispose();
  }

  /// Runs [action], turning any [AnchorError] into a readable status line.
  Future<void> _guard(String label, Future<void> Function() action) async {
    setState(() => _status = '$label...');
    try {
      await action();
    } on AnchorError catch (error) {
      // The sealed hierarchy is what makes a useful message possible: each case
      // implies a different response.
      setState(() => _status = switch (error) {
            AnchorRevoked() => 'Access was revoked. Pick the folder again.',
            AnchorStale() => 'The folder moved. Pick it again.',
            AnchorUnavailable() => 'Unavailable right now -- retry later.',
            AnchorQuotaExceeded() => 'Too many saved folders. Release some.',
            AnchorTokenMalformed() => 'That is not a valid anchor token.',
            _ => '${error.runtimeType}: ${error.message}',
          });
    }
  }

  Future<void> _pick() => _guard('Opening picker', () async {
        final anchor = await FileAnchor.pickDirectory(purpose: 'Choose a folder');
        if (anchor == null) {
          setState(() => _status = 'Cancelled.');
          return;
        }
        _tokenField.text = anchor.token;
        setState(() {
          _anchor = anchor;
          _status = 'Anchored "${anchor.displayName}".';
        });
        await _refresh();
      });

  Future<void> _resolve() => _guard('Resolving token', () async {
        final anchor = await FileAnchor.resolve(_tokenField.text.trim());
        setState(() {
          _anchor = anchor;
          _status = 'Resolved "${anchor.displayName}"'
              '${anchor.isStale ? ' (was stale, re-save the token)' : ''}.';
        });
        await _refresh();
      });

  Future<void> _refresh() async {
    final anchor = _anchor;
    if (anchor == null) return;
    // use() is a no-op on Android but required on iOS; always wrap I/O in it.
    final entries = await anchor.use(() => anchor.list().take(200).toList());
    setState(() => _entries = entries);
  }

  Future<void> _write() => _guard('Writing', () async {
        final anchor = _anchor!;
        await anchor.use(() async {
          await anchor.writeAsString(
            'file_anchor_demo.txt',
            'Written at ${DateTime.now().toIso8601String()}\n',
          );
        });
        setState(() => _status = 'Wrote file_anchor_demo.txt.');
        await _refresh();
      });

  @override
  Widget build(BuildContext context) {
    final anchor = _anchor;
    return Scaffold(
      appBar: AppBar(title: const Text('file_anchor')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(onPressed: _pick, child: const Text('Pick folder')),
                OutlinedButton(
                  onPressed: _tokenField.text.isEmpty ? null : _resolve,
                  child: const Text('Resolve token'),
                ),
                OutlinedButton(
                  onPressed: anchor == null ? null : _write,
                  child: const Text('Write a file'),
                ),
                OutlinedButton(
                  onPressed: anchor == null ? null : _refresh,
                  child: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenField,
              maxLines: 2,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              decoration: const InputDecoration(
                labelText: 'Durable token',
                helperText: 'Copy it, restart the app, paste it, press Resolve.',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            if (anchor != null)
              Text('capabilities: ${anchor.capabilities}',
                  style: Theme.of(context).textTheme.bodySmall),
            const Divider(),
            Expanded(
              child: _entries.isEmpty
                  ? const Center(child: Text('No entries listed yet.'))
                  : ListView.builder(
                      itemCount: _entries.length,
                      itemBuilder: (context, i) {
                        final entry = _entries[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(entry.isDirectory
                              ? Icons.folder_outlined
                              : Icons.description_outlined),
                          title: Text(entry.relativePath),
                          subtitle: entry.size == null
                              ? null
                              : Text('${entry.size} bytes'),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
