/// SkillsScreen — displays and manages installed skills.
///
/// Lists skills read from AtKeys via DataService.
/// Phase 3: add install / uninstall buttons with HITL.

import 'package:flutter/material.dart';

class SkillsScreen extends StatelessWidget {
  const SkillsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Installed Skills'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Install skill',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content:
                      Text('Skill installation via App — coming in Phase 3'),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _SkillTile(
            skillId: 'calendar',
            atSign: '@skill_cal',
            description: 'Google Calendar read/write via OAuth bridge.',
            trustScore: 0.9,
          ),
          _SkillTile(
            skillId: 'email',
            atSign: '@skill_email',
            description: 'Send emails via sendgrid or SMTP bridge (HITL).',
            trustScore: 0.85,
          ),
          _SkillTile(
            skillId: 'web_search',
            atSign: '@skill_search',
            description: 'SearXNG or Brave Search privacy-preserving search.',
            trustScore: 0.8,
          ),
        ],
      ),
    );
  }
}

class _SkillTile extends StatelessWidget {
  final String skillId;
  final String atSign;
  final String description;
  final double trustScore;

  const _SkillTile({
    required this.skillId,
    required this.atSign,
    required this.description,
    required this.trustScore,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            skillId[0].toUpperCase(),
            style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold),
          ),
        ),
        title:
            Text(skillId, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(atSign,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 12)),
            Text(description),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Trust: ', style: TextStyle(fontSize: 12)),
                _TrustBar(score: trustScore),
                Text(' ${(trustScore * 100).toInt()}%',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }
}

class _TrustBar extends StatelessWidget {
  final double score;

  const _TrustBar({required this.score});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: score,
          backgroundColor: Colors.grey.shade300,
          valueColor: AlwaysStoppedAnimation<Color>(
            score >= 0.8
                ? Colors.green
                : score >= 0.5
                    ? Colors.orange
                    : Colors.red,
          ),
        ),
      ),
    );
  }
}
