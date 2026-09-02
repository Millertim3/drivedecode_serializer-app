// lib/ui/log_panel.dart
//
// Every command in and out, plus the GATT discovery. Collapsed by default:
// during a good run nobody wants it, and the moment a unit misbehaves it is
// the only thing anyone wants.

import 'package:flutter/material.dart';

import 'theme.dart';

class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.lines, required this.onClear});

  final List<String> lines;
  final VoidCallback onClear;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  bool _expanded = false;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(LogPanel old) {
    super.didUpdateWidget(old);
    // Follow the tail. Scheduled post-frame because the new line has not been
    // laid out yet when this runs, so maxScrollExtent is still the old one.
    if (_expanded && widget.lines.length != old.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF010409),
        border: Border(top: BorderSide(color: Color(0xFF30363D))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(_expanded ? Icons.expand_more : Icons.expand_less,
                      size: 18),
                  const SizedBox(width: 8),
                  Text('Log  (${widget.lines.length})',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (_expanded)
                    TextButton(
                        onPressed: widget.onClear, child: const Text('Clear')),
                ],
              ),
            ),
          ),
          if (_expanded)
            SizedBox(
              height: 220,
              child: Scrollbar(
                controller: _scroll,
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  itemCount: widget.lines.length,
                  itemBuilder: (_, i) {
                    final line = widget.lines[i];
                    return Text(
                      line,
                      style: kMono.copyWith(
                        fontSize: 12,
                        height: 1.5,
                        color: line.startsWith('FAILED') || line.contains('WARNING')
                            ? kBad
                            : line.startsWith('>>')
                                ? kBrand
                                : const Color(0xFF8B949E),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
