# agent_log.md

所有自动化操作记录。

## 2026-08-06

### 更新开源元数据并推送 GitHub

- **需求**：更新仓库元数据并推送到 https://github.com/mannixS/pdf-ai-parser。
- **操作**：
  - 更新 `pubspec.yaml`：`repository` / `homepage` 由占位符改为 `https://github.com/mannixS/pdf-ai-parser`。
  - 使用现有 remote（`pdf-ai-parser`）执行首次提交与推送；因本机未配置 git 身份，通过 `git -c user.name=mannixS -c user.email=sml121sml121@outlook.com` 注入（未修改任何 git 配置文件）。
  - 提交信息：`Initial commit`（含全部项目文件）。

### 发布开源前的文件清理

- **需求**：项目计划发布开源，检查并删除多余无用文件。
- **操作**（用户已确认「全部删除 + 保留 pubspec.lock」）：
  - 删除 `flutter_01.log`（Flutter 工具崩溃报告日志，无用）
  - 删除 `re_test.txt`（崩溃报告残留文本，无用）
  - 删除 `build/`（Flutter 构建产物，可重新生成）
  - 删除 `.dart_tool/`（Dart 工具缓存，自动生成）
  - 创建 `.gitignore`（标准 Flutter 忽略规则：排除 `build/`、`.dart_tool/`、`.idea/` 等；**保留** `pubspec.lock`）
- 补删：`example/.dart_tool/`（验证时发现的清理遗漏缓存）及验证 `flutter pub get` 在根目录产生的 `.dart_tool/`。
- **保留**：`lib/`、`test/`、`example/`、`README.md`、`CHANGELOG.md`、`LICENSE`、`analysis_options.yaml`、`pubspec.yaml`、`pubspec.lock`。
- **验证**（独立验证子代理）：核心清理、.gitignore 规则、必需文件完整性均通过；`flutter pub get` 依赖解析成功。
- **待办提醒**：`pubspec.yaml` 中 `repository` / `homepage` 仍为 `https://example.com/...` 占位符，正式开源发布前需替换为真实地址。
