import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/chat/domain/handoff.dart';
import 'package:vibemobile/features/sessions/data/session_api.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';
import 'package:vibemobile/features/sessions/presentation/model_picker.dart';

void main() {
  group('ModelInfo (ADR 0016)', () {
    test('parses price, context and tags; detail summarizes them', () {
      final m = ModelInfo.fromJson({
        'id': 'openai:gpt-5',
        'label': 'GPT-5',
        'provider': 'openai',
        'price': {'in': 1.25, 'out': 10},
        'context': 400000,
        'tags': ['coding', 'reasoning', 3],
      });
      expect(m.priceIn, 1.25);
      expect(m.context, 400000);
      expect(m.tags, ['coding', 'reasoning']); // non-strings dropped
      expect(m.detail, r'openai · $1.25/$10 per M · 400k ctx · coding, reasoning');
    });

    test('plain entries stay plain', () {
      final m = ModelInfo.fromJson({'id': 'claude-opus-4-8', 'provider': 'anthropic'});
      expect(m.label, 'claude-opus-4-8');
      expect(m.detail, 'anthropic');
      expect(ModelInfo.fromJson({'id': 'x', 'context': 1048576}).detail, '1.0M ctx');
      expect(ModelInfo.fromJson({'id': 'x', 'context': 2000000}).detail, '2M ctx');
    });

    test('AgentPreset parses id + label', () {
      final p = AgentPreset.fromJson({'id': 'codex', 'label': 'Codex CLI'});
      expect((p.id, p.label), ('codex', 'Codex CLI'));
    });
  });

  test('filterModels matches label, id, provider and tags', () {
    const models = [
      ModelInfo(id: 'claude-opus-4-8', label: 'Claude Opus 4.8', provider: 'anthropic'),
      ModelInfo(id: 'groq:llama-4', label: 'Llama 4', provider: 'groq', tags: ['fast', 'cheap']),
      ModelInfo(id: 'google:gemini-2.5-pro', label: 'Gemini 2.5 Pro', provider: 'google'),
    ];
    expect(filterModels(models, '').length, 3);
    expect(filterModels(models, 'FAST').map((m) => m.id), ['groq:llama-4']);
    expect(filterModels(models, 'google').map((m) => m.id), ['google:gemini-2.5-pro']);
    expect(filterModels(models, 'opus').map((m) => m.id), ['claude-opus-4-8']);
  });

  group('buildHandoffPrompt', () {
    test('carries user/assistant text and tool markers, drops results', () {
      final p = buildHandoffPrompt([
        ChatMessage(role: ChatRole.user, text: 'fix the login bug'),
        ChatMessage(role: ChatRole.tool, toolName: 'Edit', toolResult: 'secret output'),
        ChatMessage(role: ChatRole.assistant, text: 'Patched auth.ts'),
        ChatMessage(role: ChatRole.result, text: 'done'),
      ]);
      expect(p, contains('User: fix the login bug\n[tool: Edit]\nAssistant: Patched auth.ts'));
      expect(p, isNot(contains('secret output')));
      expect(p, isNot(contains('omitted')));
    });

    test('keeps the most recent turns within budget', () {
      final msgs = [for (var i = 0; i < 50; i++) ChatMessage(role: ChatRole.user, text: 'turn $i ${'x' * 90}')];
      final p = buildHandoffPrompt(msgs, maxChars: 1000);
      expect(p, contains('turn 49'));
      expect(p, isNot(contains('turn 0 ')));
      expect(p, contains('(older turns omitted)'));
      final transcript = p.split('<transcript>\n')[1].split('\n</transcript>')[0];
      expect(transcript.length, lessThanOrEqualTo(1000));
    });
  });
}
