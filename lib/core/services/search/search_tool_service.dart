import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'search_service.dart';
import '../../providers/settings_provider.dart';

class SearchToolService {
  static const String toolName = 'search_web';
  static const String toolDescription = 'Search the web for information';
  
  static Map<String, dynamic> getToolDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': toolName,
        'description': toolDescription,
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query to look up online',
            },
          },
          'required': ['query'],
        },
      },
    };
  }
  
  static Future<String> executeSearch(
    String query,
    SettingsProvider settings,
  ) async {
    try {
      // Get selected search service
      final services = settings.searchServices;
      if (services.isEmpty) {
        return jsonEncode({
          'error': 'No search services configured',
        });
      }
      
      final selectedIndex = settings.searchServiceSelected.clamp(0, services.length - 1);
      final service = SearchService.getService(services[selectedIndex]);
      
      // Execute search
      final result = await service.search(
        query: query,
        commonOptions: settings.searchCommonOptions,
        serviceOptions: services[selectedIndex],
      );
      
      // Add unique IDs to each result item
      final itemsWithIds = result.items.asMap().entries.map((entry) {
        final item = entry.value;
        item.id = const Uuid().v4().substring(0, 6);
        item.index = entry.key + 1;
        return item;
      }).toList();
      
      // Return formatted result
      return jsonEncode({
        if (result.answer != null) 'answer': result.answer,
        'items': itemsWithIds.map((item) => item.toJson()).toList(),
      });
    } catch (e) {
      return jsonEncode({
        'error': 'Search failed: $e',
      });
    }
  }
  
  static String getSystemPrompt() {
    return '''
## search_web 工具

当用户询问需要实时信息或最新数据的问题时，使用 search_web 搜索。

### 引用格式
搜索结果含 index 和 id，引用格式: `内容 [citation](index:id)`
- 引用**紧跟**相关内容之后（标点后），不得集中在末尾
- 正确: `据报道，该事件发生在昨天。[citation](1:a1b2c3)`
- 错误: 全部引用堆在回答最后
''';
  }
}