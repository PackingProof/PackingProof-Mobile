package app.packingproof.mobile

import android.content.Context

/**
 * 录像存储与电脑确认策略。
 *
 * 数值由 Dart 端 `lib/models/backup_storage_policy.dart` 在启动时下发，这里只负责
 * 保存与读取。[FALLBACK] 仅在下发前使用（例如开机后未打开 App 的后台清理），必须与
 * Dart 端保持一致，由 `test/backup_storage_policy_contract_test.dart` 守门。
 */
internal data class BackupStoragePolicy(
    val minimumBytes: Long,
    val warningBytes: Long,
    val targetBytes: Long,
    val deleteUnbackedOnPressure: Boolean,
) {
    companion object {
        // 仅用于下发前，必须与 Dart 端 BackupStoragePolicy 的数值一致。
        val FALLBACK = BackupStoragePolicy(
            minimumBytes = 1L * 1024 * 1024 * 1024,
            warningBytes = 4L * 1024 * 1024 * 1024,
            targetBytes = 4L * 1024 * 1024 * 1024,
            deleteUnbackedOnPressure = true,
        )
    }
}

internal object BackupStoragePolicyStore {
    private const val PREFS = "lan_backup_storage_policy"

    fun save(context: Context, request: Map<String?, Any?>) {
        val current = current(context)
        val next = BackupStoragePolicy(
            minimumBytes = (request["storageMinimumBytes"] as? Number)?.toLong()
                ?: current.minimumBytes,
            warningBytes = (request["storageWarningBytes"] as? Number)?.toLong()
                ?: current.warningBytes,
            targetBytes = (request["storageTargetBytes"] as? Number)?.toLong()
                ?: current.targetBytes,
            deleteUnbackedOnPressure = (request["storageDeleteUnbackedOnPressure"] as? Boolean)
                ?: current.deleteUnbackedOnPressure,
        )
        if (next == current) return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong("minimumBytes", next.minimumBytes)
            .putLong("warningBytes", next.warningBytes)
            .putLong("targetBytes", next.targetBytes)
            .putBoolean("deleteUnbackedOnPressure", next.deleteUnbackedOnPressure)
            .apply()
    }

    fun current(context: Context): BackupStoragePolicy {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val fallback = BackupStoragePolicy.FALLBACK
        return BackupStoragePolicy(
            minimumBytes = prefs.getLong("minimumBytes", fallback.minimumBytes),
            warningBytes = prefs.getLong("warningBytes", fallback.warningBytes),
            targetBytes = prefs.getLong("targetBytes", fallback.targetBytes),
            deleteUnbackedOnPressure = prefs.getBoolean(
                "deleteUnbackedOnPressure",
                fallback.deleteUnbackedOnPressure,
            ),
        )
    }
}
