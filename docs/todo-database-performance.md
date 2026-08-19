# 数据库性能优化 TODO

> 来源：数据库性能排查结论，并按评审意见收敛后的实施范围。未提交代码，仅作为待办清单。

## 评审采纳结论

评审意见总体合理。以下按“先做、缓做、不做”重新收束，避免为了数据库化而扩大改造面。

## 第一阶段：直接实施

- [x] `lib/services/recording_database.dart`：`upsertSessions` 去掉事务内逐条 `SELECT created_at` 和逐条 insert；先批量读取 `created_at`，再使用 `Batch` 或 `INSERT ... ON CONFLICT(id) DO UPDATE`。
- [x] `lib/services/recording_database.dart`：`_sessionRow` 不要在 SQLite 事务内做 `file.exists()` / `file.length()`；文件 stat 提前到事务外，并避免同一 session 重复 stat。接受文件状态与 DB 状态之间的短暂不一致，按可重试方式处理。
- [x] `lib/services/recording_database.dart`：`markDeleted` 改为批量 update，删除日志使用批量 insert，文件大小在事务外统计。
- [x] `lib/services/recording_database.dart`：为 `pruneMissingSessions` 增加轻量查询，只取 `id/file_path/missing_at`，避免全量 `payload_json` 解码。
- [x] `lib/screens/recordings_screen.dart`：日期、关键词筛选下推 SQL；来源和备份状态先消除最明显的全量循环，不要求所有展示态过滤都数据库化。
- [x] `lib/controllers/packing_session_controller.dart` / `lib/services/lan_backup_service.dart`：把 `_snapshot.jobs` 按规范化 `file_path` 建 Map，消除 `_registerSessionsForRetention`、`_pruneDeletedBackupSessions`、`backupAll` 里的明显 `O(n × m)`。

### UI 约束

- [x] `lib/screens/recordings_screen.dart`：UI `build` 期间禁止同步文件系统 IO 和全量业务状态计算；文件存在性、备份状态应在数据加载/缓存阶段预计算，而不是每次 rebuild 重算。
- [x] `lib/screens/recordings_screen.dart`：数据库中的 `missing_at` / `file_path` 只作为快速路径，不能替代必要的 `File.exists` 确认；真正需要播放、删除或判定本地可用时仍以文件系统为准。

## 第二阶段：确认细节后再做

- [x] `lib/services/session_repository.dart`：`_resolveAndRepair` 每批只扫描一次录像目录，建立临时 `basename -> path` 映射，避免每条缺失录像重复递归扫描。
- [x] 实施前先确认 basename 是否保证唯一；不把 `basename` 直接当作永久数据库唯一键，除非现有命名规则能证明唯一。
- [ ] `lib/services/recording_database.dart`：`queryBackupBatch` 的 `DISTINCT file_path` 分页 + `IN` 二次查询，可择机合并，但不进入第一阶段核心改造。

## 明确不做

- [ ] 不把 `settings.json` 迁移到 SQLite：设置对象小且非高频热点，收益不足以覆盖复杂度。
- [ ] 不把 diagnostics log 迁移到 SQLite：日志非主链路，现有有限长截断已够用。
