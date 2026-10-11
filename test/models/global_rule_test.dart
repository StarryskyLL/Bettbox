import 'dart:convert';

import 'package:bett_box/models/clash_config.dart';
import 'package:bett_box/models/config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the global split-routing rules that are appended ahead of the
/// subscription rules on every core start. mihomo evaluates rules top-down,
/// so the ordering contract is the part most worth pinning down.
void main() {
  group('GlobalRule 序列化', () {
    test('默认启用，并可通过 JSON 往返保持状态', () {
      final rule = GlobalRule.value('DOMAIN-SUFFIX,google.com,PROXY');
      expect(rule.enable, isTrue);
      expect(rule.value, 'DOMAIN-SUFFIX,google.com,PROXY');

      final restored = GlobalRule.fromJson(
        jsonDecode(jsonEncode(rule.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, rule.id);
      expect(restored.value, rule.value);
      expect(restored.enable, isTrue);
    });

    test('禁用状态能够往返', () {
      final rule = GlobalRule.value(
        'DOMAIN-SUFFIX,example.com,DIRECT',
        enable: false,
      );
      final restored = GlobalRule.fromJson(
        jsonDecode(jsonEncode(rule.toJson())) as Map<String, dynamic>,
      );
      expect(restored.enable, isFalse);
    });

    test('缺少 enable 字段时回退为启用，保证旧配置可读', () {
      final restored = GlobalRule.fromJson({
        'id': 'legacy',
        'value': 'MATCH,GLOBAL',
      });
      expect(restored.enable, isTrue);
    });
  });

  group('runningValue 过滤', () {
    test('只保留启用且非空的规则，并保持声明顺序', () {
      final rules = [
        GlobalRule.value('DOMAIN-SUFFIX,a.com,PROXY'),
        GlobalRule.value('DOMAIN-SUFFIX,b.com,PROXY', enable: false),
        GlobalRule.value('MATCH,DIRECT'),
        GlobalRule.value(''),
      ];

      expect(rules.runningValue, [
        'DOMAIN-SUFFIX,a.com,PROXY',
        'MATCH,DIRECT',
      ]);
    });

    test('全部禁用时不下发任何规则', () {
      final rules = [
        GlobalRule.value('MATCH,DIRECT', enable: false),
        GlobalRule.value('MATCH,REJECT', enable: false),
      ];
      expect(rules.runningValue, isEmpty);
    });

    test('空列表安全', () {
      expect(<GlobalRule>[].runningValue, isEmpty);
    });
  });

  group('与规则编辑器的桥接', () {
    test('asRule 保留 id 与 value，便于编辑器原地更新', () {
      final rule = GlobalRule.value('GEOIP,CN,DIRECT');
      expect(rule.asRule.id, rule.id);
      expect(rule.asRule.value, rule.value);
    });

    test('mergeEdited 采用编辑后的 value 但保留 id 与启用状态', () {
      final rule = GlobalRule.value('GEOIP,CN,DIRECT', enable: false);
      final merged = rule.mergeEdited(
        rule.asRule.copyWith(value: 'GEOIP,US,PROXY'),
      );
      expect(merged.id, rule.id);
      expect(merged.value, 'GEOIP,US,PROXY');
      expect(merged.enable, isFalse);
    });
  });

  group('注入顺序契约', () {
    test('全局规则被前置到订阅规则之前', () {
      final merged = mergeGlobalRules(
        globalRules: ['DOMAIN-SUFFIX,mine.com,PROXY'],
        rules: ['MATCH,DIRECT'],
      );
      expect(merged, ['DOMAIN-SUFFIX,mine.com,PROXY', 'MATCH,DIRECT']);
    });

    test('用户规则优先于内置守卫，守卫优先于订阅规则', () {
      final withGuards = <dynamic>[
        'AND,((IP-CIDR,127.0.0.0/8,no-resolve),(DST-PORT,7890)),REJECT',
        'MATCH,DIRECT',
      ];
      final merged = mergeGlobalRules(
        globalRules: ['DOMAIN-SUFFIX,mine.com,PROXY'],
        rules: withGuards,
      );
      // 手写规则优先级最高；守卫规则全是 REJECT，排在其后不影响安全性
      expect(merged[0], 'DOMAIN-SUFFIX,mine.com,PROXY');
      expect(merged[1], withGuards.first);
      expect(merged.last, 'MATCH,DIRECT');
      expect(merged.length, 3);
    });

    test('无全局规则时原样返回，不做多余拷贝', () {
      final rules = <dynamic>['MATCH,DIRECT'];
      expect(
        identical(mergeGlobalRules(globalRules: [], rules: rules), rules),
        isTrue,
      );
    });
  });

  group('Config 兼容性', () {
    test('缺少 globalRules 的旧配置回退为空列表', () {
      final config = Config.fromJson({'themeProps': <String, Object?>{}});
      expect(config.globalRules, isEmpty);
    });

    test('globalRules 随配置一起序列化', () {
      final config = Config(
        themeProps: defaultThemeProps,
        globalRules: [
          GlobalRule.value('DOMAIN-SUFFIX,a.com,PROXY'),
          GlobalRule.value('MATCH,DIRECT', enable: false),
        ],
      );

      final restored = Config.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );
      expect(restored.globalRules.length, 2);
      expect(restored.globalRules.runningValue, ['DOMAIN-SUFFIX,a.com,PROXY']);
    });
  });
}
