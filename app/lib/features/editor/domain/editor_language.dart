import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

/// Language name used when the extension is unknown: shown unhighlighted.
const plaintextLanguage = 'plaintext';

final _modes = <String, Mode>{
  'dart': langDart,
  'typescript': langTypescript,
  'javascript': langJavascript,
  'json': langJson,
  'yaml': langYaml,
  'markdown': langMarkdown,
  'python': langPython,
  'bash': langBash,
  'kotlin': langKotlin,
  'java': langJava,
  'swift': langSwift,
  'go': langGo,
  'rust': langRust,
  'c': langC,
  'cpp': langCpp,
  'csharp': langCsharp,
  'xml': langXml,
  'css': langCss,
  'scss': langScss,
  'sql': langSql,
  'ini': langIni, // also TOML
  'gradle': langGradle,
  'dockerfile': langDockerfile,
  'makefile': langMakefile,
};

const _byExtension = <String, String>{
  'dart': 'dart',
  'ts': 'typescript', 'tsx': 'typescript',
  'js': 'javascript', 'jsx': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
  'json': 'json', 'jsonc': 'json',
  'yaml': 'yaml', 'yml': 'yaml',
  'md': 'markdown', 'markdown': 'markdown',
  'py': 'python',
  'sh': 'bash', 'bash': 'bash', 'zsh': 'bash',
  'kt': 'kotlin', 'kts': 'kotlin',
  'java': 'java',
  'swift': 'swift',
  'go': 'go',
  'rs': 'rust',
  'c': 'c', 'h': 'c',
  'cpp': 'cpp', 'cc': 'cpp', 'cxx': 'cpp', 'hpp': 'cpp',
  'cs': 'csharp',
  'html': 'xml', 'htm': 'xml', 'xml': 'xml', 'svg': 'xml',
  'css': 'css',
  'scss': 'scss',
  'sql': 'sql',
  'toml': 'ini', 'ini': 'ini', 'cfg': 'ini',
  'gradle': 'gradle',
  'mk': 'makefile',
};

const _byFileName = <String, String>{
  'dockerfile': 'dockerfile',
  'makefile': 'makefile',
};

/// The highlight language for [path] (by file name, then extension), else [plaintextLanguage].
String languageFor(String path) {
  final name = path.split('/').last.toLowerCase();
  final byName = _byFileName[name];
  if (byName != null) return byName;
  final dot = name.lastIndexOf('.');
  if (dot < 0) return plaintextLanguage;
  return _byExtension[name.substring(dot + 1)] ?? plaintextLanguage;
}

/// The re_highlight rule set for a [languageFor] name; null for plaintext.
Mode? modeFor(String language) => _modes[language];
