import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'skill_parser.dart';
import 'skill_store.dart';

/// Handles import/export of Agent Skills.
///
/// Import sources:
/// - ZIP file (local filesystem)
/// - GitHub URL (single skill directory or full repo)
///
/// Export:
/// - Skill directory → ZIP
class AgentSkillImportExport {
  AgentSkillImportExport._();

  // ═══════════════════════════════════════════════════════════════════════════
  // Import from ZIP
  // ═══════════════════════════════════════════════════════════════════════════

  /// Import a skill from a ZIP file into the default skills directory.
  ///
  /// The ZIP must contain a SKILL.md file either at the root or within a
  /// single top-level directory. Returns the imported skill directory path
  /// on success, or an error message on failure.
  static Future<({String? path, String? error})> importFromZip(
    String zipFilePath,
  ) async {
    try {
      final zipFile = File(zipFilePath);
      if (!await zipFile.exists()) {
        return (path: null, error: 'ZIP file not found');
      }

      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      return _extractArchive(archive);
    } catch (e) {
      debugPrint('AgentSkillImportExport: importFromZip error: $e');
      return (path: null, error: 'Failed to import ZIP: $e');
    }
  }

  /// Import a skill from raw ZIP bytes.
  static Future<({String? path, String? error})> importFromZipBytes(
    Uint8List bytes,
  ) async {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      return _extractArchive(archive);
    } catch (e) {
      debugPrint('AgentSkillImportExport: importFromZipBytes error: $e');
      return (path: null, error: 'Failed to import ZIP: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Import from GitHub URL
  // ═══════════════════════════════════════════════════════════════════════════

  /// Import a skill from a GitHub repository URL.
  ///
  /// Supported URL formats:
  /// - `https://github.com/owner/repo` (downloads entire repo)
  /// - `https://github.com/owner/repo/tree/main/path/to/skill` (specific dir)
  ///
  /// Downloads as ZIP, extracts the relevant skill directory.
  static Future<({String? path, String? error})> importFromGitHub(
    String url,
  ) async {
    try {
      final parsed = _parseGitHubUrl(url);
      if (parsed == null) {
        return (path: null, error: 'Invalid GitHub URL format');
      }

      final (:owner, :repo, :ref, :subpath) = parsed;

      // Download ZIP from GitHub API
      final zipUrl =
          'https://github.com/$owner/$repo/archive/refs/heads/$ref.zip';
      debugPrint('AgentSkillImportExport: Downloading $zipUrl');

      final response = await http.get(Uri.parse(zipUrl)).timeout(
            const Duration(seconds: 30),
          );

      if (response.statusCode != 200) {
        return (
          path: null,
          error: 'GitHub download failed (HTTP ${response.statusCode})',
        );
      }

      final archive = ZipDecoder().decodeBytes(response.bodyBytes);

      // If a subpath was specified, extract only that directory
      if (subpath != null && subpath.isNotEmpty) {
        return _extractArchiveSubpath(archive, subpath, '$repo-$ref');
      }

      return _extractArchive(archive);
    } catch (e) {
      debugPrint('AgentSkillImportExport: importFromGitHub error: $e');
      return (path: null, error: 'Failed to import from GitHub: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Export to ZIP
  // ═══════════════════════════════════════════════════════════════════════════

  /// Export a skill directory to a ZIP file.
  ///
  /// Returns the path of the created ZIP file.
  static Future<({String? path, String? error})> exportToZip(
    String skillDirectoryPath,
    String outputPath,
  ) async {
    try {
      final dir = Directory(skillDirectoryPath);
      if (!await dir.exists()) {
        return (path: null, error: 'Skill directory not found');
      }

      final archive = Archive();
      final skillName = p.basename(skillDirectoryPath);

      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final relative = p.relative(entity.path, from: skillDirectoryPath);
          final bytes = await entity.readAsBytes();
          final archivePath = p.posix.join(skillName, relative.replaceAll('\\', '/'));
          archive.addFile(ArchiveFile(
            archivePath,
            bytes.length,
            bytes,
          ));
        }
      }

      final zipData = ZipEncoder().encode(archive);

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(zipData);

      return (path: outputPath, error: null);
    } catch (e) {
      debugPrint('AgentSkillImportExport: exportToZip error: $e');
      return (path: null, error: 'Failed to export ZIP: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal helpers
  // ═══════════════════════════════════════════════════════════════════════════

  /// Extract an archive, finding the SKILL.md and placing the skill in the
  /// default skills directory.
  static Future<({String? path, String? error})> _extractArchive(
    Archive archive,
  ) async {
    // Find SKILL.md in the archive
    ArchiveFile? skillMd;
    String? skillMdDir;

    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      final basename = p.posix.basename(name);
      if (basename == 'SKILL.md') {
        // Prefer the shallowest SKILL.md
        final dir = p.posix.dirname(name);
        if (skillMd == null || dir.split('/').length < skillMdDir!.split('/').length) {
          skillMd = file;
          skillMdDir = dir;
        }
      }
    }

    if (skillMd == null) {
      return (path: null, error: 'No SKILL.md found in archive');
    }

    // Parse metadata to get skill name
    final content = utf8.decode(skillMd.content as List<int>);
    final meta = SkillParser.parseMetadata(content, '');
    if (meta == null) {
      return (path: null, error: 'Invalid SKILL.md format');
    }

    // Determine output directory
    final defaultDir = await AgentSkillStore.getDefaultSkillsDirectory();
    final targetDir = p.join(defaultDir, meta.name);

    // Extract files
    await _extractFiles(archive, skillMdDir!, targetDir);

    return (path: targetDir, error: null);
  }

  /// Extract a specific subpath from a GitHub archive.
  static Future<({String? path, String? error})> _extractArchiveSubpath(
    Archive archive,
    String subpath,
    String repoPrefix,
  ) async {
    // GitHub archives have a prefix like "repo-branch/"
    final prefix = '$repoPrefix/$subpath'.replaceAll('\\', '/');

    // Find SKILL.md under the prefix
    ArchiveFile? skillMd;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      if (name.startsWith(prefix) && p.posix.basename(name) == 'SKILL.md') {
        final rel = name.substring(prefix.length);
        // Only accept SKILL.md at the root of the subpath
        if (rel == '/SKILL.md' || rel == 'SKILL.md') {
          skillMd = file;
          break;
        }
      }
    }

    if (skillMd == null) {
      return (path: null, error: 'No SKILL.md found at path "$subpath"');
    }

    final content = utf8.decode(skillMd.content as List<int>);
    final meta = SkillParser.parseMetadata(content, '');
    if (meta == null) {
      return (path: null, error: 'Invalid SKILL.md format in subpath');
    }

    final defaultDir = await AgentSkillStore.getDefaultSkillsDirectory();
    final targetDir = p.join(defaultDir, meta.name);

    // Extract only files under the prefix
    final normalizedPrefix = prefix.endsWith('/') ? prefix : '$prefix/';
    final targetArchive = Archive();
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      if (name.startsWith(normalizedPrefix)) {
        final relative = name.substring(normalizedPrefix.length);
        if (relative.isNotEmpty) {
          targetArchive.addFile(ArchiveFile(
            relative,
            file.size,
            file.content,
          ));
        }
      }
    }

    await _extractFilesFromArchive(targetArchive, targetDir);

    return (path: targetDir, error: null);
  }

  /// Extract files from archive under [prefix] to [targetDir].
  static Future<void> _extractFiles(
    Archive archive,
    String prefix,
    String targetDir,
  ) async {
    final normalizedPrefix = prefix == '.' ? '' : (prefix.endsWith('/') ? prefix : '$prefix/');

    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      String relativePath;
      if (normalizedPrefix.isEmpty) {
        relativePath = name;
      } else if (name.startsWith(normalizedPrefix)) {
        relativePath = name.substring(normalizedPrefix.length);
      } else {
        continue;
      }

      if (relativePath.isEmpty) continue;

      final outputPath = p.join(targetDir, relativePath.replaceAll('/', Platform.pathSeparator));

      // Security: path traversal check
      if (!p.isWithin(targetDir, outputPath) && p.normalize(outputPath) != p.normalize(targetDir)) {
        continue;
      }

      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      await outputFile.writeAsBytes(file.content as List<int>);
    }
  }

  /// Extract all files from a flat archive (no prefix stripping).
  static Future<void> _extractFilesFromArchive(
    Archive archive,
    String targetDir,
  ) async {
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');

      final outputPath = p.join(targetDir, name.replaceAll('/', Platform.pathSeparator));
      if (!p.isWithin(targetDir, outputPath) && p.normalize(outputPath) != p.normalize(targetDir)) {
        continue;
      }

      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      await outputFile.writeAsBytes(file.content as List<int>);
    }
  }

  /// Parse a GitHub URL into components.
  static ({String owner, String repo, String ref, String? subpath})?
      _parseGitHubUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    if (uri.host != 'github.com') return null;

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;

    final owner = segments[0];
    final repo = segments[1].replaceAll('.git', '');

    // Simple repo URL: github.com/owner/repo
    if (segments.length == 2) {
      return (owner: owner, repo: repo, ref: 'main', subpath: null);
    }

    // Tree URL: github.com/owner/repo/tree/branch/path/to/skill
    if (segments.length >= 4 && segments[2] == 'tree') {
      final ref = segments[3];
      final subpath =
          segments.length > 4 ? segments.sublist(4).join('/') : null;
      return (owner: owner, repo: repo, ref: ref, subpath: subpath);
    }

    // Default: assume main branch
    return (owner: owner, repo: repo, ref: 'main', subpath: null);
  }
}
