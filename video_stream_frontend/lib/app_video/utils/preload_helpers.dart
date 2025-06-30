import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

Future<Uint8List> _downloadImageBytes(String url) async {
  final response = await http.get(Uri.parse(url));
  return response.bodyBytes;
}

Future<Uint8List> preloadImageBytesInIsolate(String url) async {
  return compute(_downloadImageBytes, url);
}

Future<Map<String, dynamic>> _fetchJson(String url) async {
  final response = await http.get(Uri.parse(url));
  return response.statusCode == 200
      ? Map<String, dynamic>.from(jsonDecode(response.body))
      : {};
}

Future<Map<String, dynamic>> fetchJsonInIsolate(String url) async {
  return compute(_fetchJson, url);
}
